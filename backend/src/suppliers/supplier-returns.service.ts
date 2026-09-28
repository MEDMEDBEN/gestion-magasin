import { HttpStatus, Injectable } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { ActorContext, writeAudit } from '../audit/audit-writer';
import { AuthenticatedUser } from '../common/auth.decorators';
import { BusinessException } from '../common/business.exception';
import { nextDocumentNumber } from '../common/document-number';
import { ErrorCode } from '../common/error-codes';
import { assertSameMutation, runOnce } from '../common/idempotency';
import { roundMoney } from '../common/money';
import { formatDA, formatDateTime } from '../common/pdf/pdf';
import { formatQuantity, parseQuantity } from '../common/quantity';
import { Prisma } from '../generated/prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import { renderA4Document } from '../sales/sale-document';
import { storeIdentity } from '../settings/store-settings';
import { StockLedgerService } from '../stock/stock-ledger.service';
import {
  CreateSupplierReturnDto,
  SupplierReturnDto,
} from './dto/supplier-return.dto';

type Db = Prisma.TransactionClient;
const Decimal = Prisma.Decimal;

/// Une ligne de réception de ce produit chez ce fournisseur.
export interface ReceivedLot {
  receivedQuantity: Prisma.Decimal;
  unitPriceHt: number;
  /// TTC figé à la réception : ce qu'elle a ajouté à la dette.
  lineTotalTtc: number;
  taxRate: Prisma.Decimal;
}

/// Valeur de `quantity` unités renvoyées quand `gone` l'ont déjà été. Les lots
/// (du PLUS RÉCENT au plus ancien) sont consommés dans l'ordre, chacun au
/// prorata de SON prix et de SON TTC figé : la dette baisse de ce que ces
/// lots y avaient ajouté, jamais plus (Σ renvoyé ≤ Σ reçu). Arrondi CUMULÉ par
/// lot : un lot renvoyé en entier, en un ou plusieurs retours, rend exactement
/// son TTC — aucun reliquat de 0,01 DA. `null` : plus que le reçu non renvoyé.
export function valueReturn(
  lots: ReceivedLot[],
  gone: Prisma.Decimal,
  quantity: Prisma.Decimal,
): {
  lineTotalHt: number;
  lineTotalTtc: number;
  taxRate: Prisma.Decimal;
} | null {
  const to = gone.plus(quantity);
  let start = new Decimal(0);
  let ht = 0;
  let ttc = 0;
  let taxRate: Prisma.Decimal | null = null;
  for (const lot of lots) {
    if (lot.receivedQuantity.lessThanOrEqualTo(0)) continue;
    const end = start.plus(lot.receivedQuantity);
    const a = Decimal.max(gone, start).minus(start);
    const b = Decimal.min(to, end).minus(start);
    if (b.greaterThan(a)) {
      const upTo = (q: Prisma.Decimal) => ({
        ht: roundMoney(new Decimal(lot.unitPriceHt).mul(q)),
        ttc: roundMoney(
          new Decimal(lot.lineTotalTtc).mul(q).div(lot.receivedQuantity),
        ),
      });
      const [pa, pb] = [upTo(a), upTo(b)];
      ht += pb.ht - pa.ht;
      ttc += pb.ttc - pa.ttc;
      taxRate ??= lot.taxRate;
    }
    start = end;
  }
  if (quantity.lessThanOrEqualTo(0) || to.greaterThan(start)) return null;
  // Le TTC fait foi (c'est lui qui a chargé la dette) ; la TVA jamais < 0.
  return {
    lineTotalHt: Math.min(ht, ttc),
    lineTotalTtc: ttc,
    taxRate: taxRate!,
  };
}

/// Retour fournisseur (P1 bis n°21l) : marchandise renvoyée, dans UNE
/// transaction (règle 3) — stock RETOUR_FOURNISSEUR (journal, jamais sous 0),
/// dette fournisseur réduite du TTC (lue par `SuppliersService.debt`), numéro
/// RF-AAAA-NNNNN, audit. Le prix n'est JAMAIS saisi : chaque unité renvoyée
/// vaut ce que sa réception avait ajouté à la dette (`valueReturn`) ; la
/// quantité est bornée par ce qui a été reçu de lui et pas encore renvoyé.
@Injectable()
export class SupplierReturnsService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly config: ConfigService,
    private readonly ledger: StockLedgerService,
  ) {}

  async create(
    dto: CreateSupplierReturnDto,
    user: AuthenticatedUser,
    actor: ActorContext,
  ): Promise<SupplierReturnDto> {
    const replay = async () => {
      const done = await this.prisma.supplierReturn.findUnique({
        where: { clientMutationId: dto.clientMutationId },
        include: { lines: true },
      });
      if (!done) return null;
      const key = (lines: { productId: string; quantity: string }[]) =>
        lines
          .map(
            (l) =>
              `${l.productId}|${formatQuantity(parseQuantity(l.quantity))}`,
          )
          .sort()
          .join(',');
      assertSameMutation(
        done,
        user.id,
        done.supplierId === dto.supplierId &&
          done.locationId === dto.locationId &&
          done.purchaseOrderId === (dto.purchaseOrderId ?? null) &&
          done.reason === dto.reason &&
          key(dto.lines) ===
            key(
              done.lines.map((l) => ({
                productId: l.productId,
                quantity: l.quantity.toFixed(3),
              })),
            ),
        {
          code: ErrorCode.CONFLICT,
          message: 'Ce retour fournisseur a déjà été enregistré autrement',
        },
      );
      return SupplierReturnsService.toDto(done);
    };
    return runOnce(replay, () =>
      this.prisma.$transaction((tx) => this.createInTx(tx, dto, user, actor)),
    );
  }

  private async createInTx(
    tx: Db,
    dto: CreateSupplierReturnDto,
    user: AuthenticatedUser,
    actor: ActorContext,
  ): Promise<SupplierReturnDto> {
    await tx.$queryRaw`SELECT "id" FROM "Supplier" WHERE "id" = ${dto.supplierId}::uuid FOR UPDATE`;
    const supplier = await tx.supplier.findUnique({
      where: { id: dto.supplierId },
    });
    if (!supplier) {
      throw new BusinessException(
        ErrorCode.NOT_FOUND,
        'Fournisseur introuvable',
        HttpStatus.NOT_FOUND,
      );
    }
    // Même borne que la réception : la marchandise part du magasin ou du
    // dépôt, jamais du TRANSIT (elle y bloquerait le transfert en cours).
    const origin = await tx.location.findUnique({
      where: { id: dto.locationId },
      select: { type: true },
    });
    if (origin?.type !== 'MAGASIN' && origin?.type !== 'DEPOT') {
      throw new BusinessException(
        ErrorCode.VALIDATION_FAILED,
        'locationId : la marchandise part du magasin ou du dépôt',
        HttpStatus.UNPROCESSABLE_ENTITY,
      );
    }
    const productIds = dto.lines.map((l) => l.productId);
    if (new Set(productIds).size !== productIds.length) {
      throw new BusinessException(
        ErrorCode.VALIDATION_FAILED,
        'lines : un produit par ligne',
        HttpStatus.UNPROCESSABLE_ENTITY,
      );
    }
    if (dto.purchaseOrderId) {
      // La commande citée doit être celle de CE fournisseur ET avoir livré
      // chaque produit renvoyé (ses rappels d'échéance en tiennent compte).
      const order = await tx.purchaseOrder.findUnique({
        where: { id: dto.purchaseOrderId },
        select: { supplierId: true },
      });
      const delivered = await tx.receptionLine.findMany({
        where: {
          productId: { in: productIds },
          reception: { purchaseOrderId: dto.purchaseOrderId },
        },
        distinct: ['productId'],
        select: { productId: true },
      });
      if (
        order?.supplierId !== dto.supplierId ||
        delivered.length !== productIds.length
      ) {
        throw new BusinessException(
          ErrorCode.VALIDATION_FAILED,
          'purchaseOrderId : commande d’un autre fournisseur, ou qui n’a pas livré ces produits',
          HttpStatus.UNPROCESSABLE_ENTITY,
        );
      }
    }
    // Reçu de CE fournisseur (du plus récent au plus ancien) et déjà renvoyé.
    const [received, sentBack] = await Promise.all([
      tx.receptionLine.findMany({
        where: {
          productId: { in: productIds },
          reception: { supplierId: supplier.id },
        },
        orderBy: [{ reception: { createdAt: 'desc' } }, { id: 'desc' }],
        select: {
          productId: true,
          receivedQuantity: true,
          unitPriceHt: true,
          lineTotalTtc: true,
          purchaseLine: { select: { taxRate: true } },
          product: { select: { taxRate: { select: { rate: true } } } },
        },
      }),
      tx.supplierReturnLine.groupBy({
        by: ['productId'],
        where: {
          productId: { in: productIds },
          supplierReturn: { supplierId: supplier.id },
        },
        _sum: { quantity: true },
      }),
    ]);
    const lines = dto.lines.map((input) => {
      const quantity = parseQuantity(input.quantity, 'lines.quantity');
      const lots = received
        .filter((r) => r.productId === input.productId)
        .map((r) => ({
          receivedQuantity: r.receivedQuantity,
          unitPriceHt: r.unitPriceHt,
          lineTotalTtc: r.lineTotalTtc,
          taxRate:
            r.purchaseLine?.taxRate ??
            r.product.taxRate?.rate ??
            new Decimal(0),
        }));
      const gone =
        sentBack.find((r) => r.productId === input.productId)?._sum.quantity ??
        new Decimal(0);
      const value = valueReturn(lots, gone, quantity);
      if (!value) {
        const got = lots.reduce(
          (s, l) => s.plus(l.receivedQuantity),
          new Decimal(0),
        );
        throw new BusinessException(
          ErrorCode.VALIDATION_FAILED,
          `Quantité renvoyée invalide : au plus ${formatQuantity(got.minus(gone))} ` +
            '(reçu de ce fournisseur et pas encore renvoyé)',
          HttpStatus.UNPROCESSABLE_ENTITY,
        );
      }
      return {
        productId: input.productId,
        quantity,
        // Prix moyen affiché ; les totaux (lots réels) font foi.
        unitPriceHt: roundMoney(new Decimal(value.lineTotalHt).div(quantity)),
        taxRate: value.taxRate,
        lineTotalHt: value.lineTotalHt,
        lineTaxAmount: value.lineTotalTtc - value.lineTotalHt,
        lineTotalTtc: value.lineTotalTtc,
      };
    });
    const totalHt = lines.reduce((s, l) => s + l.lineTotalHt, 0);
    const totalTax = lines.reduce((s, l) => s + l.lineTaxAmount, 0);
    const number = await nextDocumentNumber(tx, 'RETOUR_FOURNISSEUR', 'RF', 5);
    const created = await tx.supplierReturn.create({
      data: {
        id: dto.id,
        number,
        supplierId: supplier.id,
        purchaseOrderId: dto.purchaseOrderId ?? null,
        userId: user.id,
        locationId: dto.locationId,
        totalHt,
        totalTax,
        totalTtc: totalHt + totalTax,
        reason: dto.reason,
        clientMutationId: dto.clientMutationId,
        lines: { create: lines },
      },
      include: { lines: true },
    });
    for (const l of [...lines].sort((a, b) =>
      a.productId.localeCompare(b.productId),
    )) {
      await this.ledger.applyMovement(tx, {
        productId: l.productId,
        locationId: dto.locationId,
        quantity: l.quantity.negated(),
        type: 'RETOUR_FOURNISSEUR',
        operationType: 'SUPPLIER_RETURN',
        operationId: created.id,
        userId: user.id,
        comment: `Retour ${number} à ${supplier.name}`,
      });
    }
    await writeAudit(tx, actor, {
      action: 'CREATE',
      entityType: 'SupplierReturn',
      entityId: created.id,
      newValue: {
        number,
        supplier: supplier.name,
        locationId: dto.locationId,
        purchaseOrderId: dto.purchaseOrderId ?? null,
        lines: lines.map((l) => ({
          productId: l.productId,
          quantity: formatQuantity(l.quantity),
          lineTotalTtc: l.lineTotalTtc,
        })),
        totalTtc: created.totalTtc,
        reason: dto.reason,
      },
    });
    return SupplierReturnsService.toDto(created);
  }

  async forSupplier(supplierId: string): Promise<SupplierReturnDto[]> {
    const rows = await this.prisma.supplierReturn.findMany({
      where: { supplierId },
      orderBy: { createdAt: 'desc' },
      take: 200,
    });
    return rows.map(SupplierReturnsService.toDto);
  }

  /// Bon de retour fournisseur (A4, accompagne la marchandise).
  async renderDocument(id: string): Promise<{ filename: string; pdf: Buffer }> {
    const row = await this.prisma.supplierReturn.findUnique({
      where: { id },
      include: { lines: true, supplier: true },
    });
    if (!row) {
      throw new BusinessException(
        ErrorCode.NOT_FOUND,
        'Retour introuvable',
        HttpStatus.NOT_FOUND,
      );
    }
    const products = await this.prisma.product.findMany({
      where: { id: { in: row.lines.map((l) => l.productId) } },
      select: { id: true, name: true, sku: true, unit: true },
    });
    const pdf = await renderA4Document({
      title: 'BON DE RETOUR',
      pdfTitle: `Retour fournisseur ${row.number}`,
      info: [`N° ${row.number}`, `Date : ${formatDateTime(row.createdAt)}`],
      store: await storeIdentity(this.prisma, this.config, false),
      partyLabel: 'Fournisseur',
      customer: {
        name: row.supplier.name,
        address: row.supplier.address,
        phone: row.supplier.phone,
      },
      products: new Map(products.map((p) => [p.id, p])),
      lines: row.lines.map((l) => ({
        productId: l.productId,
        quantity: formatQuantity(l.quantity),
        unitPriceHt: l.unitPriceHt,
        taxRate: l.taxRate.toFixed(2),
        lineTotalHt: l.lineTotalHt,
        lineTaxAmount: l.lineTaxAmount,
      })),
      totalHt: row.totalHt,
      totalTtc: row.totalTtc,
      after: [['À déduire de notre dette', formatDA(row.totalTtc)]],
      footer: `Motif : ${row.reason}`,
    });
    return { filename: `${row.number}.pdf`, pdf };
  }

  static toDto(row: {
    id: string;
    number: string;
    supplierId: string;
    purchaseOrderId: string | null;
    locationId: string;
    totalHt: number;
    totalTax: number;
    totalTtc: number;
    reason: string;
    createdAt: Date;
  }): SupplierReturnDto {
    return {
      id: row.id,
      number: row.number,
      supplierId: row.supplierId,
      purchaseOrderId: row.purchaseOrderId,
      locationId: row.locationId,
      totalHt: row.totalHt,
      totalTax: row.totalTax,
      totalTtc: row.totalTtc,
      reason: row.reason,
      createdAt: row.createdAt,
    };
  }
}
