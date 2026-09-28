import { HttpStatus, Injectable } from '@nestjs/common';
import { ActorContext, writeAudit } from '../audit/audit-writer';
import { parseApiDate } from '../common/api-date';
import { AuthenticatedUser } from '../common/auth.decorators';
import { BusinessException } from '../common/business.exception';
import { localDate, nextDocumentNumber } from '../common/document-number';
import { parseSort } from '../common/dto/pagination.dto';
import { ErrorCode } from '../common/error-codes';
import { runOnce } from '../common/idempotency';
import { PERMISSIONS } from '../common/permissions';
import { formatDateTime } from '../common/pdf/pdf';
import { formatQuantity } from '../common/quantity';
import { Prisma } from '../generated/prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import {
  ConvertQuoteDto,
  CreateQuoteDto,
  QuoteDto,
  QuoteListDto,
  QuoteListQueryDto,
  QuoteStatus,
} from './dto/quote.dto';
import { CreateSaleDto, SaleDto } from './dto/sale.dto';
import { renderA4Document, storeIdentity } from './sale-document';
import { ConfigService } from '@nestjs/config';
import { SalesService } from './sales.service';

type Db = Prisma.TransactionClient;

const QUOTE_INCLUDE = {
  lines: { orderBy: { id: 'asc' } },
  customer: { select: { name: true } },
  convertedSale: { select: { id: true } },
} as const;

type QuoteRow = Prisma.QuoteGetPayload<{ include: typeof QUOTE_INCLUDE }>;

const QUOTE_SORT_FIELDS = ['createdAt', 'number'] as const;

/// Un devis qui n'a pas abouti peut encore expirer ; un devis converti ou
/// refusé est un fait acquis.
const OPEN_STATUSES = ['BROUILLON', 'ENVOYE', 'ACCEPTE'] as const;

/// Transitions permises : d'où l'on part pour arriver où.
const TRANSITIONS: Record<
  'send' | 'accept' | 'refuse',
  {
    from: readonly string[];
    to: 'ENVOYE' | 'ACCEPTE' | 'REFUSE';
  }
> = {
  send: { from: ['BROUILLON'], to: 'ENVOYE' },
  accept: { from: ['BROUILLON', 'ENVOYE'], to: 'ACCEPTE' },
  refuse: { from: ['BROUILLON', 'ENVOYE', 'ACCEPTE'], to: 'REFUSE' },
};

/// Devis (P1 n°21a, spec §8quater).
///
/// Prix : la MÊME règle que la vente (`SalesService.priceCart`). Stock : jamais
/// touché — seule la vente issue de la conversion crée des mouvements.
/// Visibilité : partagée entre ADMIN et VENDEURS (un client qui revient ne
/// retombe pas toujours sur le même vendeur) — à confirmer par MEDMEDBEN, voir
/// `docs/permissions.md`.
@Injectable()
export class QuotesService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly sales: SalesService,
    private readonly config: ConfigService,
  ) {}

  async create(
    dto: CreateQuoteDto,
    user: AuthenticatedUser,
    actor: ActorContext,
  ): Promise<QuoteDto> {
    const validUntil = QuotesService.validUntil(dto.validUntil);
    return this.prisma.$transaction(async (tx) => {
      // Renvoi (réponse perdue) : le MÊME compte retrouve SON devis, jamais un
      // second. Un id déjà pris par un autre compte reste un conflit.
      const existing = dto.id
        ? await tx.quote.findUnique({
            where: { id: dto.id },
            include: QUOTE_INCLUDE,
          })
        : null;
      if (existing) {
        if (existing.userId !== user.id) {
          throw new BusinessException(
            ErrorCode.CONFLICT,
            'Cet identifiant de devis est déjà pris',
            HttpStatus.CONFLICT,
          );
        }
        return QuotesService.toDto(existing);
      }
      const customer = dto.customerId
        ? await tx.customer.findFirst({
            where: { id: dto.customerId, isActive: true },
          })
        : null;
      if (dto.customerId && !customer) {
        throw new BusinessException(
          ErrorCode.VALIDATION_FAILED,
          'Client introuvable ou inactif',
          HttpStatus.UNPROCESSABLE_ENTITY,
        );
      }
      const priced = await SalesService.priceCart(
        tx,
        customer,
        dto.lines,
        user.permissions.includes(PERMISSIONS.SALE_DISCOUNT),
      );
      const quote = await tx.quote.create({
        data: {
          id: dto.id,
          number: await nextDocumentNumber(tx, 'DEVIS', 'DV', 5),
          customerId: customer?.id ?? null,
          userId: user.id,
          validUntil,
          totalHt: priced.totalHt,
          totalTax: priced.totalTax,
          totalTtc: priced.totalTtc,
          note: dto.note ?? null,
          lines: {
            create: priced.lines.map((line) => ({
              productId: line.productId,
              priceTierId: line.priceTierId,
              quantity: line.quantity,
              unitPriceHt: line.unitPriceHt,
              taxRate: line.taxRate,
              discountAmount: line.discountAmount,
              lineTotalHt: line.lineTotalHt,
              lineTaxAmount: line.lineTaxAmount,
              lineTotalTtc: line.lineTotalTtc,
            })),
          },
        },
        include: QUOTE_INCLUDE,
      });
      await writeAudit(tx, actor, {
        action: 'CREATE',
        entityType: 'Quote',
        entityId: quote.id,
        newValue: {
          number: quote.number,
          totalTtc: quote.totalTtc,
          // Même trace que `POST /sales` (décision 2026-09-22) : le prix
          // promis au client, s'il n'est pas celui du tarif.
          priceOverrides: QuotesService.overrides(priced.lines),
        },
      });
      return QuotesService.toDto(quote);
    });
  }

  async findAll(query: QuoteListQueryDto): Promise<QuoteListDto> {
    const where = QuotesService.statusFilter(query.status);
    if (query.customerId) where.customerId = query.customerId;
    if (query.q) {
      where.OR = [
        { number: { contains: query.q, mode: 'insensitive' } },
        { customer: { name: { contains: query.q, mode: 'insensitive' } } },
      ];
    }
    const [rows, total] = await Promise.all([
      this.prisma.quote.findMany({
        where,
        include: QUOTE_INCLUDE,
        skip: (query.page - 1) * query.limit,
        take: query.limit,
        orderBy: [
          parseSort(query.sort, QUOTE_SORT_FIELDS, { createdAt: 'desc' }),
          { id: 'desc' },
        ],
      }),
      this.prisma.quote.count({ where }),
    ]);
    return {
      data: rows.map((row) => QuotesService.toDto(row)),
      meta: { page: query.page, limit: query.limit, total },
    };
  }

  async findOne(id: string): Promise<QuoteDto> {
    const quote = await this.prisma.quote.findUnique({
      where: { id },
      include: QUOTE_INCLUDE,
    });
    if (!quote) throw QuotesService.notFound();
    return QuotesService.toDto(quote);
  }

  /// Envoyé, accepté, refusé — sous verrou de ligne : deux clics simultanés ne
  /// font pas deux transitions.
  async transition(
    id: string,
    action: keyof typeof TRANSITIONS,
    actor: ActorContext,
  ): Promise<QuoteDto> {
    const rule = TRANSITIONS[action];
    return this.prisma.$transaction(async (tx) => {
      const quote = await QuotesService.lock(tx, id);
      const status = QuotesService.effectiveStatus(quote);
      if (status === 'EXPIRE' && action !== 'refuse') {
        throw QuotesService.expired(quote.number);
      }
      if (!rule.from.includes(quote.status)) {
        throw new BusinessException(
          ErrorCode.INVALID_STATE_TRANSITION,
          `Devis ${quote.number} : impossible depuis le statut ${status}`,
          HttpStatus.CONFLICT,
        );
      }
      const updated = await tx.quote.update({
        where: { id },
        data: { status: rule.to },
        include: QUOTE_INCLUDE,
      });
      await writeAudit(tx, actor, {
        action: 'UPDATE',
        entityType: 'Quote',
        entityId: id,
        oldValue: { status: quote.status },
        newValue: { status: rule.to },
      });
      return QuotesService.toDto(updated);
    });
  }

  /// Devis ACCEPTÉ → vente, « en un clic » (spec §8quater). La vente passe par le
  /// MÊME cœur que `POST /sales` (caisse, crédit et plafond, anti-stock-négatif,
  /// plancher de prix) ; le devis passe à CONVERTI dans la MÊME transaction.
  /// Le prix promis est repris ; une remise accordée par l'admin dans le devis
  /// aussi ; le plancher du coût d'achat, lui, reste vérifié au jour de la vente.
  async convert(
    id: string,
    dto: ConvertQuoteDto,
    user: AuthenticatedUser,
    actor: ActorContext,
  ): Promise<SaleDto> {
    const saleDto = (quote: QuoteRow): CreateSaleDto => ({
      clientMutationId: dto.clientMutationId,
      id: dto.id,
      customerId: quote.customerId ?? undefined,
      cashSessionId: dto.cashSessionId,
      paidAmount: dto.paidAmount,
      expectedTotalTtc: dto.expectedTotalTtc,
      dueDate: dto.dueDate,
      note: `Devis ${quote.number}`,
      lines: quote.lines.map((line) => ({
        productId: line.productId,
        quantity: formatQuantity(line.quantity),
        unitPriceHt: line.unitPriceHt,
        // Le prix vient du devis : il ne doit pas buter sur un tarif changé
        // depuis (409 `SALE_TOTAL_CHANGED`), c'est la promesse faite au client.
        priceEdited: true,
        discountAmount: line.discountAmount,
      })),
    });

    return runOnce(
      // Renvoi de la même conversion : la vente déjà créée, rien de plus.
      async () => {
        const existing = await this.prisma.sale.findUnique({
          where: { clientMutationId: dto.clientMutationId },
          select: { quoteId: true },
        });
        if (!existing) return null;
        const quote = await this.prisma.quote.findUnique({
          where: { id },
          include: QUOTE_INCLUDE,
        });
        if (!quote || existing.quoteId !== id) {
          throw new BusinessException(
            ErrorCode.SALE_ALREADY_RECORDED,
            'Cette clé d’opération désigne déjà une autre vente',
            HttpStatus.CONFLICT,
          );
        }
        return this.sales.replay(this.prisma, saleDto(quote), user);
      },
      () =>
        this.prisma.$transaction(async (tx) => {
          const quote = await QuotesService.lock(tx, id);
          // Deux envois SIMULTANÉS de la même clé : le second a attendu le
          // verrou pendant que le premier convertissait. Il rend la vente déjà
          // faite, comme un renvoi — le verrou l'empêche d'atteindre la
          // contrainte unique que `runOnce` sait relire.
          if (quote.status === 'CONVERTI') {
            const done = await tx.sale.findUnique({
              where: { clientMutationId: dto.clientMutationId },
              select: { quoteId: true },
            });
            if (done?.quoteId === id) {
              return (await this.sales.replay(tx, saleDto(quote), user))!;
            }
          }
          if (QuotesService.effectiveStatus(quote) === 'EXPIRE') {
            throw QuotesService.expired(quote.number);
          }
          if (quote.status !== 'ACCEPTE') {
            throw new BusinessException(
              ErrorCode.INVALID_STATE_TRANSITION,
              quote.status === 'CONVERTI'
                ? `Devis ${quote.number} déjà converti en vente`
                : `Devis ${quote.number} : seul un devis ACCEPTÉ se convertit`,
              HttpStatus.CONFLICT,
            );
          }
          const sale = await this.sales
            .createInTx(tx, saleDto(quote), user, new Date(), false, {
              quoteId: id,
            })
            .catch((error: unknown) => {
              // Les prix du devis sont figés ; seul un taux de TVA changé depuis
              // fait bouger le total. Le devis ne peut plus être tenu tel quel.
              if (
                error instanceof BusinessException &&
                (error.getResponse() as { code?: string }).code ===
                  ErrorCode.SALE_TOTAL_CHANGED
              ) {
                throw new BusinessException(
                  ErrorCode.SALE_TOTAL_CHANGED,
                  `Devis ${quote.number} : la TVA a changé depuis, le total n’est plus le même — établissez un nouveau devis`,
                  HttpStatus.CONFLICT,
                );
              }
              throw error;
            });
          await tx.quote.update({
            where: { id },
            data: { status: 'CONVERTI' },
          });
          await writeAudit(tx, actor, {
            action: 'UPDATE',
            entityType: 'Quote',
            entityId: id,
            oldValue: { status: 'ACCEPTE' },
            newValue: { status: 'CONVERTI', sale: sale.number },
          });
          // Même trace que `POST /sales` : un prix promis sous (ou sur) le
          // tarif du jour est une vente à prix modifié, que l'admin doit voir.
          const overrides = QuotesService.overrides(sale.lines);
          if (overrides.length > 0) {
            await writeAudit(tx, actor, {
              action: 'CREATE',
              entityType: 'Sale',
              entityId: sale.id,
              newValue: {
                number: sale.number,
                quote: quote.number,
                priceOverrides: overrides,
              },
            });
          }
          return sale;
        }),
    );
  }

  /// PDF du devis : le même gabarit A4 que la facture. Imprimable sans les
  /// mentions légales (ce n'est pas une facture).
  async renderDocument(id: string): Promise<{ filename: string; pdf: Buffer }> {
    const quote = await this.findOne(id);
    const [products, customer, seller] = await Promise.all([
      this.prisma.product.findMany({
        where: { id: { in: quote.lines.map((l) => l.productId) } },
        select: { id: true, name: true, sku: true, unit: true },
      }),
      quote.customerId
        ? this.prisma.customer.findUnique({
            where: { id: quote.customerId },
            select: { name: true, address: true, phone: true },
          })
        : null,
      this.prisma.user.findUnique({
        where: { id: quote.userId },
        select: { fullName: true },
      }),
    ]);
    const stamp: Partial<Record<QuoteStatus, string>> = {
      REFUSE: 'DEVIS REFUSÉ',
      EXPIRE: 'DEVIS EXPIRÉ',
      CONVERTI: 'DEVIS CONVERTI EN VENTE',
    };
    const pdf = await renderA4Document({
      title: 'DEVIS',
      pdfTitle: `Devis ${quote.number}`,
      info: [
        `N° ${quote.number}`,
        `Date : ${formatDateTime(quote.createdAt)}`,
        quote.validUntil
          ? `Valable jusqu’au ${quote.validUntil.split('-').reverse().join('/')}`
          : 'Sans date de validité',
      ],
      store: storeIdentity(this.config, false),
      customer,
      products: new Map(products.map((p) => [p.id, p])),
      lines: quote.lines,
      totalHt: quote.totalHt,
      totalTtc: quote.totalTtc,
      after: [],
      stamp: stamp[quote.status],
      footer:
        `Établi par : ${seller?.fullName ?? ''} — ` +
        'Devis sans engagement de stock : la disponibilité est confirmée à la vente.',
    });
    return { filename: `${quote.number}.pdf`, pdf };
  }

  // ── Outils ──────────────────────────────────────────────────────────────

  private static validUntil(day: string | undefined): Date | null {
    if (!day) return null;
    const date = parseApiDate(day, 'validUntil');
    if (day < localDate(new Date())) {
      throw new BusinessException(
        ErrorCode.VALIDATION_FAILED,
        'La date de validité ne peut pas être passée',
        HttpStatus.UNPROCESSABLE_ENTITY,
      );
    }
    return date;
  }

  /// `EXPIRE` n'est jamais écrit : un devis ouvert dont le dernier jour de
  /// validité est passé (jour d'Alger) est LU expiré.
  static effectiveStatus(quote: {
    status: string;
    validUntil: Date | null;
  }): QuoteStatus {
    const open = (OPEN_STATUSES as readonly string[]).includes(quote.status);
    if (
      open &&
      quote.validUntil &&
      quote.validUntil.toISOString().slice(0, 10) < localDate(new Date())
    ) {
      return 'EXPIRE';
    }
    return quote.status as QuoteStatus;
  }

  /// Filtre SQL du statut LU, cohérent avec `effectiveStatus`.
  private static statusFilter(status?: QuoteStatus): Prisma.QuoteWhereInput {
    if (!status) return {};
    const today = parseApiDate(localDate(new Date()), 'jour');
    const expired: Prisma.QuoteWhereInput = {
      status: { in: [...OPEN_STATUSES] },
      validUntil: { lt: today },
    };
    if (status === 'EXPIRE') return expired;
    if ((OPEN_STATUSES as readonly string[]).includes(status)) {
      return { status, NOT: expired };
    }
    return { status };
  }

  private static async lock(tx: Db, id: string): Promise<QuoteRow> {
    await tx.$queryRaw`SELECT "id" FROM "Quote" WHERE "id" = ${id}::uuid FOR UPDATE`;
    const quote = await tx.quote.findUnique({
      where: { id },
      include: QUOTE_INCLUDE,
    });
    if (!quote) throw QuotesService.notFound();
    return quote;
  }

  /// Lignes dont le prix appliqué n'est pas celui du tarif, ou remisées (même
  /// forme que `SalesService.priceOverrides`).
  private static overrides(
    lines: {
      productId: string;
      unitPriceHt: number;
      tariffPriceHt: number | null;
      discountAmount: number;
    }[],
  ) {
    return lines
      .filter((l) => l.unitPriceHt !== l.tariffPriceHt || l.discountAmount > 0)
      .map((l) => ({
        productId: l.productId,
        tariffPriceHt: l.tariffPriceHt,
        unitPriceHt: l.unitPriceHt,
        discountAmount: l.discountAmount,
      }));
  }

  private static notFound() {
    return new BusinessException(
      ErrorCode.NOT_FOUND,
      'Devis introuvable',
      HttpStatus.NOT_FOUND,
    );
  }

  private static expired(number: string) {
    return new BusinessException(
      ErrorCode.QUOTE_EXPIRED,
      `Devis ${number} expiré : établissez-en un nouveau (prix et stock ont pu changer)`,
      HttpStatus.CONFLICT,
    );
  }

  private static toDto(quote: QuoteRow): QuoteDto {
    return {
      id: quote.id,
      number: quote.number,
      status: QuotesService.effectiveStatus(quote),
      customerId: quote.customerId,
      customerName: quote.customer?.name ?? null,
      userId: quote.userId,
      validUntil: quote.validUntil?.toISOString().slice(0, 10) ?? null,
      totalHt: quote.totalHt,
      totalTax: quote.totalTax,
      totalTtc: quote.totalTtc,
      note: quote.note,
      saleId: quote.convertedSale?.id ?? null,
      createdAt: quote.createdAt,
      lines: quote.lines.map((line) => ({
        id: line.id,
        productId: line.productId,
        quantity: formatQuantity(line.quantity),
        unitPriceHt: line.unitPriceHt,
        taxRate: line.taxRate.toFixed(2),
        discountAmount: line.discountAmount,
        lineTotalHt: line.lineTotalHt,
        lineTaxAmount: line.lineTaxAmount,
        lineTotalTtc: line.lineTotalTtc,
      })),
    };
  }
}
