import { HttpStatus, Injectable } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { ActorContext, writeAudit } from '../audit/audit-writer';
import { AuthenticatedUser, RoleCode } from '../common/auth.decorators';
import { BusinessException } from '../common/business.exception';
import { nextDocumentNumber } from '../common/document-number';
import { ErrorCode } from '../common/error-codes';
import { assertSameMutation, runOnce } from '../common/idempotency';
import { roundMoney, taxAmount } from '../common/money';
import { formatDA, formatDateTime } from '../common/pdf/pdf';
import { formatQuantity, parseQuantity } from '../common/quantity';
import { Prisma, SaleReturn, SaleReturnLine } from '../generated/prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import { storeIdentity, StoreIdentity } from '../settings/store-settings';
import { StockLedgerService } from '../stock/stock-ledger.service';
import { CashSessionsService } from './cash-sessions.service';
import { CreateSaleReturnDto, SaleReturnDto } from './dto/sale-return.dto';
import { renderA4Document } from './sale-document';
import { SalesService } from './sales.service';

type Db = Prisma.TransactionClient;
type ReturnWithLines = SaleReturn & { lines: SaleReturnLine[] };

/// Retours client (P1 bis n°21l). Une vente VALIDÉE rend tout ou partie de ses
/// lignes, dans UNE transaction (règle 3) :
/// - stock : mouvement RETOUR_CLIENT au lieu de la vente (règle 2) ;
/// - argent : ESPECES → sortie de la caisse ouverte de l'opérateur, au plus ce
///   que le client a réellement payé sur cette vente ; DETTE → un règlement
///   « Avoir RC-… » sur la vente : TOUTES les formules de dette (fiche client,
///   retard, reste de la vente, rappels, tableau de bord) le comptent sans
///   règle nouvelle. Il ne se contre-passe pas (garde dans CustomersService).
/// - vente FACTURÉE : facture d'avoir AV-AAAA-NNNNNN, numéro serveur sans trou
///   (règle 11), identité du magasin figée comme sur la facture.
/// Montants au prorata de la ligne vendue (net de remise) ; le dernier retour
/// d'une ligne prend le RESTE exact (jamais d'écart d'arrondi cumulé).
@Injectable()
export class SaleReturnsService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly config: ConfigService,
    private readonly ledger: StockLedgerService,
  ) {}

  async create(
    saleId: string,
    dto: CreateSaleReturnDto,
    user: AuthenticatedUser,
    actor: ActorContext,
  ): Promise<SaleReturnDto> {
    const replay = async () => {
      const done = await this.prisma.saleReturn.findUnique({
        where: { clientMutationId: dto.clientMutationId },
        include: { lines: true },
      });
      if (!done) return null;
      const asked = dto.lines
        .map(
          (l) => `${l.saleLineId}|${formatQuantity(parseQuantity(l.quantity))}`,
        )
        .sort()
        .join(',');
      const kept = done.lines
        .map((l) => `${l.saleLineId}|${formatQuantity(l.quantity)}`)
        .sort()
        .join(',');
      assertSameMutation(
        done,
        user.id,
        done.saleId === saleId &&
          done.refundMethod === dto.refundMethod &&
          asked === kept,
        {
          code: ErrorCode.CONFLICT,
          message: 'Ce retour a déjà été enregistré avec un autre contenu',
        },
      );
      return SaleReturnsService.toDto(done);
    };
    return runOnce(replay, () =>
      this.prisma.$transaction((tx) =>
        this.createInTx(tx, saleId, dto, user, actor),
      ),
    );
  }

  private async createInTx(
    tx: Db,
    saleId: string,
    dto: CreateSaleReturnDto,
    user: AuthenticatedUser,
    actor: ActorContext,
  ): Promise<SaleReturnDto> {
    await tx.$queryRaw`SELECT "id" FROM "Sale" WHERE "id" = ${saleId}::uuid FOR UPDATE`;
    const sale = await tx.sale.findUnique({
      where: { id: saleId },
      include: { lines: true },
    });
    if (!sale) {
      throw new BusinessException(
        ErrorCode.NOT_FOUND,
        'Vente introuvable',
        HttpStatus.NOT_FOUND,
      );
    }
    if (sale.status !== 'VALIDEE') {
      throw new BusinessException(
        ErrorCode.INVALID_STATE_TRANSITION,
        'Une vente annulée ne reçoit pas de retour',
        HttpStatus.CONFLICT,
      );
    }
    if (sale.customerId) {
      await tx.$queryRaw`SELECT "id" FROM "Customer" WHERE "id" = ${sale.customerId}::uuid FOR UPDATE`;
    }

    // Quantités et montants déjà rendus, par ligne vendue.
    const previous = await tx.saleReturnLine.groupBy({
      by: ['saleLineId'],
      where: { saleLine: { saleId } },
      _sum: { quantity: true, lineTotalHt: true, lineTaxAmount: true },
    });
    const already = new Map(previous.map((p) => [p.saleLineId, p._sum]));
    const seen = new Set<string>();
    const lines = dto.lines.map((input) => {
      const line = sale.lines.find((l) => l.id === input.saleLineId);
      if (!line || seen.has(line.id)) {
        throw new BusinessException(
          ErrorCode.VALIDATION_FAILED,
          'lines : ligne absente de cette vente, ou en double',
          HttpStatus.UNPROCESSABLE_ENTITY,
        );
      }
      seen.add(line.id);
      const quantity = parseQuantity(input.quantity, 'lines.quantity');
      const back = already.get(line.id);
      const returned = back?.quantity ?? new Prisma.Decimal(0);
      const left = line.quantity.minus(returned);
      if (quantity.lessThanOrEqualTo(0) || quantity.greaterThan(left)) {
        throw new BusinessException(
          ErrorCode.VALIDATION_FAILED,
          `Quantité rendue invalide : au plus ${formatQuantity(left)} pour cette ligne`,
          HttpStatus.UNPROCESSABLE_ENTITY,
        );
      }
      const all = quantity.equals(left);
      const lineTotalHt = all
        ? line.lineTotalHt - (back?.lineTotalHt ?? 0)
        : roundMoney(
            new Prisma.Decimal(line.lineTotalHt)
              .mul(quantity)
              .div(line.quantity),
          );
      const lineTaxAmount = all
        ? line.lineTaxAmount - (back?.lineTaxAmount ?? 0)
        : taxAmount(lineTotalHt, line.taxRate);
      return {
        line,
        quantity,
        lineTotalHt,
        lineTaxAmount,
        lineTotalTtc: lineTotalHt + lineTaxAmount,
      };
    });
    const totalHt = lines.reduce((s, l) => s + l.lineTotalHt, 0);
    const totalTax = lines.reduce((s, l) => s + l.lineTaxAmount, 0);
    const totalTtc = totalHt + totalTax;

    // Ce que la vente a encaissé / doit encore — mêmes composantes que partout.
    const [payments, refunds] = await Promise.all([
      tx.customerPayment.aggregate({
        where: { saleId },
        _sum: { amount: true },
      }),
      tx.saleReturn.groupBy({
        by: ['refundMethod'],
        where: { saleId },
        _sum: { totalTtc: true },
      }),
    ]);
    const paidLater = payments._sum.amount ?? 0;
    const refunded = (method: 'ESPECES' | 'DETTE') =>
      refunds.find((r) => r.refundMethod === method)?._sum.totalTtc ?? 0;
    // Les avoirs DETTE sont des règlements : on les retire de l'encaissé réel.
    const reallyPaid =
      sale.paidAmount + paidLater - refunded('DETTE') - refunded('ESPECES');
    const stillDue = sale.totalTtc - sale.paidAmount - paidLater;

    const number = await nextDocumentNumber(tx, 'RETOUR_CLIENT', 'RC', 5);
    let cashSessionId: string | null = null;
    if (dto.refundMethod === 'ESPECES') {
      if (totalTtc > reallyPaid) {
        throw new BusinessException(
          ErrorCode.VALIDATION_FAILED,
          `Remboursement en espèces : au plus ${formatDA(Math.max(0, reallyPaid))} ` +
            '(ce que le client a payé sur cette vente) — sinon, déduisez de sa dette',
          HttpStatus.UNPROCESSABLE_ENTITY,
        );
      }
      const session = await CashSessionsService.lockOpenSession(tx, {
        userId: user.id,
      });
      if (!session) {
        throw new BusinessException(
          ErrorCode.CASH_SESSION_REQUIRED,
          'Ouvrez votre caisse : les espèces sont rendues au client',
          HttpStatus.UNPROCESSABLE_ENTITY,
        );
      }
      await CashSessionsService.withdraw(tx, session, {
        userId: user.id,
        amount: totalTtc,
        note: `Retour ${number}`,
        saleId,
      });
      cashSessionId = session.id;
    } else {
      const debt = sale.customerId
        ? await SalesService.customerDebt(tx, sale.customerId)
        : 0;
      if (!sale.customerId || totalTtc > stillDue || totalTtc > debt) {
        throw new BusinessException(
          ErrorCode.VALIDATION_FAILED,
          `Déduction de la dette : au plus ${formatDA(Math.max(0, Math.min(stillDue, debt)))} ` +
            '(reste dû) — sinon, remboursez en espèces',
          HttpStatus.UNPROCESSABLE_ENTITY,
        );
      }
    }

    // Vente facturée : facture d'avoir, mentions vérifiées AVANT le numéro.
    let creditNoteNumber: string | null = null;
    let issuer: StoreIdentity | null = null;
    if (sale.invoiceNumber) {
      issuer = await storeIdentity(tx, this.config, true);
      creditNoteNumber = await nextDocumentNumber(tx, 'AVOIR', 'AV', 6);
    }

    const created = await tx.saleReturn.create({
      data: {
        id: dto.id,
        number,
        creditNoteNumber,
        saleId,
        userId: user.id,
        locationId: sale.locationId,
        cashSessionId,
        refundMethod: dto.refundMethod,
        totalHt,
        totalTax,
        totalTtc,
        reason: dto.reason,
        issuerSnapshot: issuer ? { ...issuer } : Prisma.JsonNull,
        clientMutationId: dto.clientMutationId,
        lines: {
          create: lines.map((l) => ({
            saleLineId: l.line.id,
            productId: l.line.productId,
            quantity: l.quantity,
            lineTotalHt: l.lineTotalHt,
            lineTaxAmount: l.lineTaxAmount,
            lineTotalTtc: l.lineTotalTtc,
          })),
        },
      },
      include: { lines: true },
    });
    if (dto.refundMethod === 'DETTE') {
      await tx.customerPayment.create({
        data: {
          customerId: sale.customerId!,
          saleId,
          userId: user.id,
          amount: totalTtc,
          method: 'AUTRE',
          note: `Avoir ${creditNoteNumber ?? number}`,
          saleReturnId: created.id,
        },
      });
    }
    // Trié par produit : ordre de verrouillage stable (comme la vente).
    for (const l of [...lines].sort((a, b) =>
      a.line.productId.localeCompare(b.line.productId),
    )) {
      await this.ledger.applyMovement(tx, {
        productId: l.line.productId,
        locationId: sale.locationId,
        quantity: l.quantity,
        type: 'RETOUR_CLIENT',
        operationType: 'SALE_RETURN',
        operationId: created.id,
        userId: user.id,
        comment: `Retour ${number} (vente ${sale.number})`,
      });
    }
    await writeAudit(tx, actor, {
      action: 'CREATE',
      entityType: 'SaleReturn',
      entityId: created.id,
      newValue: {
        number,
        creditNoteNumber,
        sale: sale.invoiceNumber ?? sale.number,
        refundMethod: dto.refundMethod,
        totalTtc,
        reason: dto.reason,
      },
    });
    return SaleReturnsService.toDto(created);
  }

  /// Retours d'une vente (le vendeur : les siennes seulement).
  async forSale(
    saleId: string,
    user: AuthenticatedUser,
  ): Promise<SaleReturnDto[]> {
    const sale = await this.prisma.sale.findUnique({ where: { id: saleId } });
    if (
      !sale ||
      (sale.userId !== user.id && !user.roles.includes(RoleCode.ADMIN))
    ) {
      throw new BusinessException(
        ErrorCode.NOT_FOUND,
        'Vente introuvable',
        HttpStatus.NOT_FOUND,
      );
    }
    const rows = await this.prisma.saleReturn.findMany({
      where: { saleId },
      include: { lines: true },
      orderBy: { createdAt: 'asc' },
    });
    return rows.map(SaleReturnsService.toDto);
  }

  /// Facture d'avoir (vente facturée) ou bon de retour, A4.
  async renderDocument(
    id: string,
    user: AuthenticatedUser,
  ): Promise<{ filename: string; pdf: Buffer }> {
    const row = await this.prisma.saleReturn.findUnique({
      where: { id },
      include: { lines: true, sale: { include: { lines: true } } },
    });
    if (
      !row ||
      (row.sale.userId !== user.id && !user.roles.includes(RoleCode.ADMIN))
    ) {
      throw new BusinessException(
        ErrorCode.NOT_FOUND,
        'Retour introuvable',
        HttpStatus.NOT_FOUND,
      );
    }
    const [products, customer] = await Promise.all([
      this.prisma.product.findMany({
        where: { id: { in: row.lines.map((l) => l.productId) } },
        select: { id: true, name: true, sku: true, unit: true },
      }),
      row.sale.customerId
        ? this.prisma.customer.findUnique({
            where: { id: row.sale.customerId },
            select: { name: true, address: true, phone: true },
          })
        : null,
    ]);
    const credit = row.creditNoteNumber;
    const pdf = await renderA4Document({
      title: credit ? 'FACTURE D’AVOIR' : 'BON DE RETOUR',
      pdfTitle: credit ? `Avoir ${credit}` : `Retour ${row.number}`,
      info: [
        `N° ${credit ?? row.number}`,
        ...(credit ? [`Retour ${row.number}`] : []),
        `Date : ${formatDateTime(row.createdAt)}`,
        `Sur ${row.sale.invoiceNumber ? `facture ${row.sale.invoiceNumber}` : `vente ${row.sale.number}`}`,
      ],
      store:
        (row.issuerSnapshot as unknown as StoreIdentity | null) ??
        (await storeIdentity(this.prisma, this.config, false)),
      customer,
      products: new Map(products.map((p) => [p.id, p])),
      lines: row.lines.map((l) => {
        const sold = row.sale.lines.find((s) => s.id === l.saleLineId)!;
        return {
          productId: l.productId,
          quantity: formatQuantity(l.quantity),
          unitPriceHt: sold.unitPriceHt,
          taxRate: sold.taxRate.toFixed(2),
          lineTotalHt: l.lineTotalHt,
          lineTaxAmount: l.lineTaxAmount,
        };
      }),
      totalHt: row.totalHt,
      totalTtc: row.totalTtc,
      after: [
        [
          row.refundMethod === 'ESPECES'
            ? 'Remboursé en espèces'
            : 'Déduit du compte client',
          formatDA(row.totalTtc),
        ],
      ],
      footer: `Motif : ${row.reason}`,
    });
    return { filename: `${credit ?? row.number}.pdf`, pdf };
  }

  static toDto(row: ReturnWithLines): SaleReturnDto {
    return {
      id: row.id,
      number: row.number,
      creditNoteNumber: row.creditNoteNumber,
      saleId: row.saleId,
      refundMethod: row.refundMethod,
      totalHt: row.totalHt,
      totalTax: row.totalTax,
      totalTtc: row.totalTtc,
      reason: row.reason,
      createdAt: row.createdAt,
      lines: row.lines.map((l) => ({
        saleLineId: l.saleLineId,
        productId: l.productId,
        quantity: formatQuantity(l.quantity),
        lineTotalHt: l.lineTotalHt,
        lineTaxAmount: l.lineTaxAmount,
        lineTotalTtc: l.lineTotalTtc,
      })),
    };
  }
}
