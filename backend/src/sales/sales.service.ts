import { HttpStatus, Injectable } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { ActorContext, writeAudit } from '../audit/audit-writer';
import { AuthenticatedUser, RoleCode } from '../common/auth.decorators';
import { parseApiDate } from '../common/api-date';
import { BusinessException } from '../common/business.exception';
import {
  localDate,
  localYear,
  nextDocumentNumber,
} from '../common/document-number';
import { ErrorCode } from '../common/error-codes';
import { assertSameMutation, runOnce } from '../common/idempotency';
import { PERMISSIONS } from '../common/permissions';
import { formatDA } from '../common/pdf/pdf';
import { formatQuantity, parseQuantity } from '../common/quantity';
import { Prisma, Sale, SaleLine } from '../generated/prisma/client';
import { parseSort } from '../common/dto/pagination.dto';
import { PrismaService } from '../prisma/prisma.service';
import { StockLedgerService } from '../stock/stock-ledger.service';
import {
  CreateSaleDto,
  SaleDto,
  SaleListDto,
  SaleListQueryDto,
  MAX_MONEY,
  SaleTypeDto,
} from './dto/sale.dto';
import { CashSessionsService } from './cash-sessions.service';
import { renderSaleDocument } from './sale-document';

type Db = Prisma.TransactionClient;
type SaleWithLines = Sale & { lines: SaleLine[] };

const SALE_INCLUDE = { lines: true } as const;

/// Tris autorisés (liste blanche, CONVENTIONS.md).
const SALE_SORT_FIELDS = ['soldAt', 'totalTtc', 'number'] as const;

/// Arrondi monétaire unique des ventes : au centime, demi vers le haut.
function roundMoney(value: Prisma.Decimal): number {
  return value.toDecimalPlaces(0, Prisma.Decimal.ROUND_HALF_UP).toNumber();
}

@Injectable()
export class SalesService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly ledger: StockLedgerService,
    private readonly config: ConfigService,
  ) {}

  /// Vente validée (CLAUDE.md règle 3) : Sale + lignes + mouvements de stock +
  /// projection + encaissement de caisse, dans UNE transaction — tout ou rien.
  async create(dto: CreateSaleDto, user: AuthenticatedUser): Promise<SaleDto> {
    // Idempotence (common/idempotency.ts) : un renvoi du même panier rend la
    // vente déjà créée ; même clé avec un autre panier → 409.
    const replay = async () => {
      const existing = await this.prisma.sale.findUnique({
        where: { clientMutationId: dto.clientMutationId },
        include: SALE_INCLUDE,
      });
      if (!existing) return null;
      // Comparaison en multi-ensembles triés : doublons et remises comptent.
      const key = (productId: string, quantity: string, discount: number) =>
        `${productId}|${quantity}|${discount}`;
      const sorted = (keys: string[]) => [...keys].sort().join(';');
      const sameCart =
        existing.paidAmount === dto.paidAmount &&
        existing.customerId === (dto.customerId ?? null) &&
        sorted(
          existing.lines.map((l) =>
            key(l.productId, formatQuantity(l.quantity), l.discountAmount),
          ),
        ) ===
          sorted(
            dto.lines.map((l) =>
              key(
                l.productId,
                formatQuantity(parseQuantity(l.quantity, 'lines.quantity')),
                l.discountAmount ?? 0,
              ),
            ),
          );
      assertSameMutation(existing, user.id, sameCart, {
        code: ErrorCode.SALE_ALREADY_RECORDED,
        message:
          `Vente déjà enregistrée : ${existing.number} (${formatDA(existing.totalTtc)}) — ` +
          'vérifiez-la avant de refaire une vente',
      });
      return this.toDto(this.prisma, existing);
    };

    return runOnce(replay, () =>
      this.prisma.$transaction(async (tx) => {
        const store = await tx.location.findFirst({
          where: { type: 'MAGASIN', isActive: true },
        });
        if (!store) {
          throw new BusinessException(
            ErrorCode.CONFLICT,
            'Aucun magasin actif : vente impossible',
            HttpStatus.CONFLICT,
          );
        }

        const customer = dto.customerId
          ? await SalesService.lockCustomer(tx, dto.customerId)
          : null;
        // Tarif du client s'il est encore actif, sinon le tarif par défaut.
        const customerTier = customer?.priceTierId
          ? await tx.priceTier.findFirst({
              where: { id: customer.priceTierId, isActive: true },
            })
          : null;
        const tier =
          customerTier ??
          (await tx.priceTier.findFirst({
            where: { isDefault: true, isActive: true },
          }));
        if (!tier) {
          throw new BusinessException(
            ErrorCode.PRICE_NOT_DEFINED,
            'Aucun tarif par défaut : l’administrateur doit en définir un',
            HttpStatus.UNPROCESSABLE_ENTITY,
          );
        }

        const canDiscount = user.permissions.includes(
          PERMISSIONS.SALE_DISCOUNT,
        );
        const lines = [];
        for (const line of dto.lines) {
          lines.push(
            await SalesService.priceLine(tx, line, tier.id, canDiscount),
          );
        }
        const totalHt = lines.reduce((sum, l) => sum + l.lineTotalHt, 0);
        const totalTax = lines.reduce((sum, l) => sum + l.lineTaxAmount, 0);
        const totalTtc = totalHt + totalTax;
        // Colonnes Int : un total démesuré est une saisie invalide, pas une 500.
        if (
          totalTtc > MAX_MONEY ||
          lines.some((l) => l.lineTotalTtc > MAX_MONEY)
        ) {
          throw new BusinessException(
            ErrorCode.VALIDATION_FAILED,
            'Montant de la vente trop élevé',
            HttpStatus.UNPROCESSABLE_ENTITY,
          );
        }

        if (
          dto.expectedTotalTtc !== undefined &&
          dto.expectedTotalTtc !== totalTtc
        ) {
          throw new BusinessException(
            ErrorCode.SALE_TOTAL_CHANGED,
            `Le total a changé : ${formatDA(totalTtc)} (prix mis à jour) — vérifiez avant d’encaisser`,
            HttpStatus.CONFLICT,
          );
        }
        if (dto.paidAmount > totalTtc) {
          throw new BusinessException(
            ErrorCode.VALIDATION_FAILED,
            'Encaissé supérieur au total : indiquez le montant gardé, pas celui reçu',
            HttpStatus.UNPROCESSABLE_ENTITY,
          );
        }

        // Espèces : rattachées à la caisse OUVERTE du vendeur (règle 12).
        const cashSession =
          dto.paidAmount > 0
            ? await CashSessionsService.lockOpenSession(tx, {
                userId: user.id,
                locationId: store.id,
              })
            : null;
        if (dto.paidAmount > 0 && !cashSession) {
          throw new BusinessException(
            ErrorCode.CASH_SESSION_REQUIRED,
            'Ouvrez votre caisse avant d’encaisser des espèces',
            HttpStatus.UNPROCESSABLE_ENTITY,
          );
        }

        // Crédit : client identifié, droit `sale.credit`, dans son plafond.
        const credit = totalTtc - dto.paidAmount;
        if (credit > 0) {
          if (!customer) {
            throw new BusinessException(
              ErrorCode.CREDIT_LIMIT_EXCEEDED,
              'Vente non soldée : choisissez le client à qui accorder le crédit',
              HttpStatus.UNPROCESSABLE_ENTITY,
            );
          }
          if (!user.permissions.includes(PERMISSIONS.SALE_CREDIT)) {
            throw new BusinessException(
              ErrorCode.FORBIDDEN_PERMISSION,
              'Permission requise pour vendre à crédit : sale.credit',
              HttpStatus.FORBIDDEN,
            );
          }
          const debt = await SalesService.customerDebt(tx, customer.id);
          if (debt + credit > customer.creditLimit) {
            throw new BusinessException(
              ErrorCode.CREDIT_LIMIT_EXCEEDED,
              `Plafond de crédit dépassé : dette ${formatDA(debt)}, crédit demandé ` +
                `${formatDA(credit)}, plafond ${formatDA(customer.creditLimit)}`,
              HttpStatus.UNPROCESSABLE_ENTITY,
            );
          }
        }

        // Échéance vérifiée APRÈS client, droit et plafond (messages plus utiles).
        const dueDate = SalesService.dueDate(dto.dueDate, credit);

        const [{ value }] = await tx.$queryRaw<{ value: bigint }[]>`
        SELECT nextval('sale_ticket_seq') AS value`;
        const soldAt = new Date();
        const sale = await tx.sale.create({
          data: {
            id: dto.id,
            clientMutationId: dto.clientMutationId,
            number: `TK-${localYear(soldAt)}-${String(value).padStart(6, '0')}`,
            customerId: customer?.id ?? null,
            userId: user.id,
            locationId: store.id,
            cashSessionId: cashSession?.id ?? null,
            totalHt,
            totalTax,
            totalTtc,
            paidAmount: dto.paidAmount,
            paymentMethod: dto.paidAmount > 0 ? 'ESPECES' : null,
            soldAt,
            dueDate,
            note: dto.note ?? null,
            lines: {
              create: lines.map(({ productId, ...rest }) => ({
                productId,
                ...rest,
              })),
            },
          },
          include: SALE_INCLUDE,
        });

        // Règle 2 : le stock ne sort que par le journal (anti-négatif compris).
        // Ordre fixe (par produit) : deux paniers A,B / B,A ne s'interbloquent pas.
        for (const line of [...sale.lines].sort((a, b) =>
          a.productId.localeCompare(b.productId),
        )) {
          await this.ledger.applyMovement(tx, {
            productId: line.productId,
            locationId: store.id,
            quantity: line.quantity.negated(),
            type: 'VENTE',
            operationType: 'SALE',
            operationId: sale.id,
            userId: user.id,
          });
        }
        if (cashSession) {
          await CashSessionsService.recordCashSale(tx, cashSession, {
            userId: user.id,
            saleId: sale.id,
            amount: dto.paidAmount,
          });
        }
        // Spec §24 : les ventes normales ne polluent pas le journal d'audit.
        return this.toDto(tx, sale);
      }),
    );
  }

  async findAll(
    query: SaleListQueryDto,
    user: AuthenticatedUser,
  ): Promise<SaleListDto> {
    const where: Prisma.SaleWhereInput = {
      ...(query.customerId && { customerId: query.customerId }),
      // Le vendeur voit SES ventes ; l'admin toutes.
      ...(!user.roles.includes(RoleCode.ADMIN) && { userId: user.id }),
    };
    const [rows, total] = await Promise.all([
      this.prisma.sale.findMany({
        where,
        include: SALE_INCLUDE,
        skip: (query.page - 1) * query.limit,
        take: query.limit,
        orderBy: [
          parseSort(query.sort, SALE_SORT_FIELDS, { soldAt: 'desc' }),
          { id: 'desc' },
        ],
      }),
      this.prisma.sale.count({ where }),
    ]);
    // Règlements ultérieurs de TOUTE la page en une requête (pas une par vente).
    const later = await this.prisma.customerPayment.groupBy({
      by: ['saleId'],
      where: { saleId: { in: rows.map((r) => r.id) } },
      _sum: { amount: true },
    });
    const paidLater = new Map(later.map((l) => [l.saleId, l._sum.amount ?? 0]));
    const data = rows.map((row) =>
      SalesService.toDtoWith(row, paidLater.get(row.id) ?? 0),
    );
    return { data, meta: { page: query.page, limit: query.limit, total } };
  }

  async findOne(id: string, user: AuthenticatedUser): Promise<SaleDto> {
    const sale = await this.prisma.sale.findUnique({
      where: { id },
      include: SALE_INCLUDE,
    });
    SalesService.assertCanSee(sale, user);
    return this.toDto(this.prisma, sale!);
  }

  /// PDF de la vente : facture A4 si un numéro légal est attribué, sinon ticket
  /// 80 mm. Mêmes droits de lecture que le détail de la vente.
  async renderDocument(
    id: string,
    user: AuthenticatedUser,
  ): Promise<{ filename: string; pdf: Buffer }> {
    const sale = await this.findOne(id, user);
    const [products, customer, seller] = await Promise.all([
      this.prisma.product.findMany({
        where: { id: { in: sale.lines.map((l) => l.productId) } },
        select: { id: true, name: true, sku: true, unit: true },
      }),
      sale.customerId
        ? this.prisma.customer.findUnique({
            where: { id: sale.customerId },
            select: { name: true, address: true, phone: true },
          })
        : null,
      this.prisma.user.findUnique({
        where: { id: sale.userId },
        select: { fullName: true },
      }),
    ]);
    const env = (key: string) =>
      this.config.get<string>(key)?.trim() || undefined;
    // Pas de facture sans mentions légales ; un ticket, lui, reste imprimable.
    if (sale.invoiceNumber && !(env('STORE_NIF') && env('STORE_RC'))) {
      throw new BusinessException(
        ErrorCode.STORE_IDENTITY_MISSING,
        'Mentions légales du magasin absentes (STORE_NIF, STORE_RC) : facture non imprimable',
        HttpStatus.UNPROCESSABLE_ENTITY,
      );
    }
    const legal = (['NIF', 'RC', 'NIS', 'AI'] as const).flatMap((key) => {
      const value = env(`STORE_${key}`);
      return value ? [`${key} : ${value}`] : [];
    });
    const pdf = await renderSaleDocument({
      sale,
      store: {
        name: env('STORE_NAME') ?? 'Magasin',
        address: env('STORE_ADDRESS'),
        phone: env('STORE_PHONE'),
        legal,
      },
      sellerName: seller?.fullName ?? '',
      customer,
      products: new Map(products.map((p) => [p.id, p])),
    });
    return { filename: `${sale.invoiceNumber ?? sale.number}.pdf`, pdf };
  }

  /// Ticket → facture : numéro légal séquentiel SANS TROU, attribué en
  /// transaction sous verrou du compteur de l'année (règle 11).
  async issueInvoice(
    id: string,
    user: AuthenticatedUser,
    actor: ActorContext,
  ): Promise<SaleDto> {
    return this.prisma.$transaction(async (tx) => {
      const sale = await SalesService.lockSale(tx, id);
      SalesService.assertCanSee(sale, user);
      if (sale!.status !== 'VALIDEE') {
        throw new BusinessException(
          ErrorCode.INVALID_STATE_TRANSITION,
          'Une vente annulée ne se facture pas',
          HttpStatus.CONFLICT,
        );
      }
      if (sale!.invoiceNumber) return this.toDto(tx, sale!);

      // UN seul instant pour l'année du numéro ET la date de facture : à minuit
      // le 31/12, jamais « FA-2026-… » daté de 2027.
      const invoicedAt = new Date();
      const invoiceNumber = await nextDocumentNumber(
        tx,
        'FACTURE',
        'FA',
        6,
        localYear(invoicedAt),
      );
      const invoiced = await tx.sale.update({
        where: { id },
        data: { type: 'FACTURE', invoiceNumber, invoicedAt },
        include: SALE_INCLUDE,
      });
      await writeAudit(tx, actor, {
        action: 'VALIDATE',
        entityType: 'Sale',
        entityId: id,
        newValue: { number: invoiced.number, invoiceNumber },
      });
      return this.toDto(tx, invoiced);
    });
  }

  /// Annulation ADMIN (règle 7) : jamais de suppression — mouvements inverses,
  /// sortie de caisse, statut ANNULEE. Une facture émise ne s'annule pas ici
  /// (document légal : avoir, hors P0).
  async cancel(
    id: string,
    user: AuthenticatedUser,
    actor: ActorContext,
  ): Promise<SaleDto> {
    return this.prisma.$transaction(async (tx) => {
      const sale = await SalesService.lockSale(tx, id);
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
          'Vente déjà annulée',
          HttpStatus.CONFLICT,
        );
      }
      if (sale.invoiceNumber) {
        throw new BusinessException(
          ErrorCode.INVALID_STATE_TRANSITION,
          'Vente facturée : l’annulation passe par un avoir',
          HttpStatus.CONFLICT,
        );
      }
      // Verrou client (comme règlement et vente) : un acompte simultané ne peut
      // pas passer entre le calcul de dette et l'annulation.
      if (sale.customerId) {
        await tx.$queryRaw`SELECT "id" FROM "Customer" WHERE "id" = ${sale.customerId}::uuid FOR UPDATE`;
      }
      const paidLater = await tx.customerPayment.aggregate({
        where: { saleId: id },
        _sum: { amount: true },
      });
      // Règlements NETS : un règlement contre-passé ne bloque plus l'annulation.
      const payments = paidLater._sum.amount ?? 0;
      // Un acompte général a pu solder cette vente : l'annuler rendrait la dette
      // négative sans remboursement prévu.
      if (sale.customerId && payments === 0) {
        const debt = await SalesService.customerDebt(tx, sale.customerId);
        if (debt - (sale.totalTtc - sale.paidAmount) < 0) {
          throw new BusinessException(
            ErrorCode.INVALID_STATE_TRANSITION,
            'Le client a déjà réglé cette vente : annulation impossible',
            HttpStatus.CONFLICT,
          );
        }
      }
      if (payments > 0) {
        throw new BusinessException(
          ErrorCode.INVALID_STATE_TRANSITION,
          'Des règlements existent sur cette vente : annulation impossible',
          HttpStatus.CONFLICT,
        );
      }
      if (sale.cashSessionId && sale.paidAmount > 0) {
        const session = await CashSessionsService.lockOpenSession(tx, {
          id: sale.cashSessionId,
        });
        if (!session) {
          throw new BusinessException(
            ErrorCode.INVALID_STATE_TRANSITION,
            'La caisse de cette vente est clôturée : annulation impossible',
            HttpStatus.CONFLICT,
          );
        }
        await CashSessionsService.withdraw(tx, session, {
          userId: user.id,
          amount: sale.paidAmount,
          saleId: id,
          note: `Annulation ${sale.number}`,
        });
      }
      for (const line of [...sale.lines].sort((a, b) =>
        a.productId.localeCompare(b.productId),
      )) {
        await this.ledger.applyMovement(tx, {
          productId: line.productId,
          locationId: sale.locationId,
          quantity: line.quantity,
          type: 'RETOUR_CLIENT',
          operationType: 'SALE',
          operationId: id,
          userId: user.id,
          comment: `Annulation ${sale.number}`,
        });
      }
      const cancelled = await tx.sale.update({
        where: { id },
        data: { status: 'ANNULEE', cancelledAt: new Date() },
        include: SALE_INCLUDE,
      });
      await writeAudit(tx, actor, {
        action: 'CANCEL',
        entityType: 'Sale',
        entityId: id,
        oldValue: { status: 'VALIDEE', totalTtc: sale.totalTtc },
        newValue: { status: 'ANNULEE' },
      });
      return this.toDto(tx, cancelled);
    });
  }

  /// Dette d'un client = ventes validées non soldées − règlements hors vente.
  /// TOUJOURS recalculée, jamais stockée.
  /// Échéance d'une vente : obligatoire dès qu'il reste du crédit (spec §9,
  /// décision MEDMEDBEN 2026-09-16), jamais dans le passé, interdite sinon.
  private static dueDate(raw: string | undefined, credit: number): Date | null {
    if (credit <= 0) {
      if (raw !== undefined) {
        throw new BusinessException(
          ErrorCode.VALIDATION_FAILED,
          'dueDate : une vente soldée n’a pas d’échéance',
          HttpStatus.UNPROCESSABLE_ENTITY,
        );
      }
      return null;
    }
    if (raw === undefined) {
      throw new BusinessException(
        ErrorCode.VALIDATION_FAILED,
        'dueDate : l’échéance est obligatoire pour une vente à crédit',
        HttpStatus.UNPROCESSABLE_ENTITY,
      );
    }
    const date = parseApiDate(raw, 'dueDate');
    if (raw.length !== 10 || raw < localDate(new Date())) {
      throw new BusinessException(
        ErrorCode.VALIDATION_FAILED,
        'dueDate : date AAAA-MM-JJ, aujourd’hui ou plus tard',
        HttpStatus.UNPROCESSABLE_ENTITY,
      );
    }
    return date;
  }

  static async customerDebt(
    db: Db | PrismaService,
    customerId: string,
  ): Promise<number> {
    return (await SalesService.customerDebts(db, [customerId])).get(
      customerId,
    )!;
  }

  /// Montant EN RETARD par client : reste dû des ventes dont l'échéance est
  /// passée, plafonné par la dette totale (un acompte général vient d'abord
  /// solder le plus ancien). Calculé pour toute une page en 2 requêtes.
  static async customerOverdue(
    db: Db | PrismaService,
    customerIds: string[],
    debts: Map<string, number>,
    now = new Date(),
  ): Promise<Map<string, number>> {
    // Une échéance est enregistrée à minuit : on compare au DÉBUT du jour local,
    // sinon une vente due aujourd'hui passerait « en retard » dès 01 h à Alger.
    const startOfToday = parseApiDate(localDate(now), 'dueDate');
    const [sales, payments] = await Promise.all([
      db.sale.groupBy({
        by: ['customerId'],
        where: {
          customerId: { in: customerIds },
          status: 'VALIDEE',
          dueDate: { lt: startOfToday },
        },
        _sum: { totalTtc: true, paidAmount: true },
      }),
      db.customerPayment.groupBy({
        by: ['customerId'],
        where: {
          customerId: { in: customerIds },
          sale: { status: 'VALIDEE', dueDate: { lt: startOfToday } },
        },
        _sum: { amount: true },
      }),
    ]);
    const overdue = new Map(customerIds.map((id) => [id, 0]));
    for (const row of sales) {
      overdue.set(
        row.customerId!,
        (row._sum.totalTtc ?? 0) - (row._sum.paidAmount ?? 0),
      );
    }
    for (const row of payments) {
      overdue.set(
        row.customerId,
        (overdue.get(row.customerId) ?? 0) - (row._sum.amount ?? 0),
      );
    }
    for (const [id, amount] of overdue) {
      overdue.set(id, Math.max(0, Math.min(amount, debts.get(id) ?? 0)));
    }
    return overdue;
  }

  /// Même calcul pour une PAGE de clients en 2 requêtes (jamais une par client).
  static async customerDebts(
    db: Db | PrismaService,
    customerIds: string[],
  ): Promise<Map<string, number>> {
    const [sales, payments] = await Promise.all([
      db.sale.groupBy({
        by: ['customerId'],
        where: { customerId: { in: customerIds }, status: 'VALIDEE' },
        _sum: { totalTtc: true, paidAmount: true },
      }),
      db.customerPayment.groupBy({
        by: ['customerId'],
        where: { customerId: { in: customerIds } },
        _sum: { amount: true },
      }),
    ]);
    const debts = new Map(customerIds.map((id) => [id, 0]));
    for (const row of sales) {
      debts.set(
        row.customerId!,
        (debts.get(row.customerId!) ?? 0) +
          (row._sum.totalTtc ?? 0) -
          (row._sum.paidAmount ?? 0),
      );
    }
    for (const row of payments) {
      debts.set(
        row.customerId,
        (debts.get(row.customerId) ?? 0) - (row._sum.amount ?? 0),
      );
    }
    return debts;
  }

  private static async priceLine(
    tx: Db,
    line: CreateSaleDto['lines'][number],
    priceTierId: string,
    canDiscount: boolean,
  ) {
    const quantity = parseQuantity(line.quantity, 'lines.quantity');
    if (quantity.lessThanOrEqualTo(0)) {
      throw new BusinessException(
        ErrorCode.VALIDATION_FAILED,
        'Quantité vendue strictement positive',
        HttpStatus.UNPROCESSABLE_ENTITY,
      );
    }
    const product = await tx.product.findUnique({
      where: { id: line.productId },
      include: { taxRate: true, prices: { where: { priceTierId } } },
    });
    if (!product?.isActive) {
      throw new BusinessException(
        ErrorCode.VALIDATION_FAILED,
        `Produit introuvable ou désactivé : ${line.productId}`,
        HttpStatus.UNPROCESSABLE_ENTITY,
      );
    }
    const price = product.prices[0];
    if (!price) {
      throw new BusinessException(
        ErrorCode.PRICE_NOT_DEFINED,
        `« ${product.name} » n’a pas de prix pour ce tarif`,
        HttpStatus.UNPROCESSABLE_ENTITY,
      );
    }
    const discount = line.discountAmount ?? 0;
    if (discount > 0 && !canDiscount) {
      throw new BusinessException(
        ErrorCode.DISCOUNT_NOT_ALLOWED,
        'Remise réservée à l’administrateur',
        HttpStatus.FORBIDDEN,
      );
    }
    const grossHt = roundMoney(new Prisma.Decimal(price.priceHt).mul(quantity));
    if (discount > grossHt) {
      throw new BusinessException(
        ErrorCode.VALIDATION_FAILED,
        `Remise supérieure au montant de la ligne « ${product.name} »`,
        HttpStatus.UNPROCESSABLE_ENTITY,
      );
    }
    const taxRate = product.taxRate?.rate ?? new Prisma.Decimal(0);
    const lineTotalHt = grossHt - discount;
    const lineTaxAmount = roundMoney(
      new Prisma.Decimal(lineTotalHt).mul(taxRate).div(100),
    );
    return {
      productId: product.id,
      priceTierId,
      quantity,
      unitPriceHt: price.priceHt,
      taxRate,
      discountAmount: discount,
      lineTotalHt,
      lineTaxAmount,
      lineTotalTtc: lineTotalHt + lineTaxAmount,
    };
  }

  private static async lockCustomer(tx: Db, id: string) {
    // Verrou : deux ventes à crédit simultanées ne dépassent pas le plafond.
    await tx.$queryRaw`SELECT "id" FROM "Customer" WHERE "id" = ${id}::uuid FOR UPDATE`;
    const customer = await tx.customer.findUnique({ where: { id } });
    if (!customer?.isActive) {
      throw new BusinessException(
        ErrorCode.VALIDATION_FAILED,
        'Client introuvable ou inactif',
        HttpStatus.UNPROCESSABLE_ENTITY,
      );
    }
    return customer;
  }

  private static async lockSale(
    tx: Db,
    id: string,
  ): Promise<SaleWithLines | null> {
    await tx.$queryRaw`SELECT "id" FROM "Sale" WHERE "id" = ${id}::uuid FOR UPDATE`;
    return tx.sale.findUnique({ where: { id }, include: SALE_INCLUDE });
  }

  private static assertCanSee(
    sale: Sale | null,
    user: AuthenticatedUser,
  ): void {
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
  }

  private async toDto(
    db: Db | PrismaService,
    sale: SaleWithLines,
  ): Promise<SaleDto> {
    const later = await db.customerPayment.aggregate({
      where: { saleId: sale.id },
      _sum: { amount: true },
    });
    return SalesService.toDtoWith(sale, later._sum.amount ?? 0);
  }

  private static toDtoWith(sale: SaleWithLines, paidLater: number): SaleDto {
    return {
      id: sale.id,
      number: sale.number,
      invoiceNumber: sale.invoiceNumber,
      invoicedAt: sale.invoicedAt,
      type: sale.type as SaleTypeDto,
      status: sale.status,
      customerId: sale.customerId,
      userId: sale.userId,
      cashSessionId: sale.cashSessionId,
      totalHt: sale.totalHt,
      totalTax: sale.totalTax,
      totalTtc: sale.totalTtc,
      paidAmount: sale.paidAmount,
      remainingAmount:
        sale.status === 'ANNULEE'
          ? 0
          : sale.totalTtc - sale.paidAmount - paidLater,
      lines: sale.lines.map((line) => ({
        id: line.id,
        productId: line.productId,
        quantity: formatQuantity(line.quantity),
        unitPriceHt: line.unitPriceHt,
        priceTierId: line.priceTierId,
        taxRate: line.taxRate.toFixed(2),
        discountAmount: line.discountAmount,
        lineTotalHt: line.lineTotalHt,
        lineTaxAmount: line.lineTaxAmount,
        lineTotalTtc: line.lineTotalTtc,
      })),
      soldAt: sale.soldAt,
      dueDate: sale.dueDate,
      cancelledAt: sale.cancelledAt,
    };
  }
}
