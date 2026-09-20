import { HttpStatus, Injectable } from '@nestjs/common';
import { ActorContext, writeAudit } from '../audit/audit-writer';
import { AuthenticatedUser } from '../common/auth.decorators';
import { BusinessException } from '../common/business.exception';
import { nextDocumentNumber } from '../common/document-number';
import { parseSort } from '../common/dto/pagination.dto';
import { ErrorCode } from '../common/error-codes';
import { assertSameMutation, runOnce } from '../common/idempotency';
import { formatQuantity, parseQuantity } from '../common/quantity';
import { Prisma, Reception, ReceptionLine } from '../generated/prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import { PurchaseOrdersService } from '../purchases/purchase-orders.service';
import { MAX_MONEY } from '../sales/dto/sale.dto';
import { StockLedgerService } from '../stock/stock-ledger.service';
import {
  CreateReceptionDto,
  ReceptionDto,
  ReceptionListDto,
  ReceptionListQueryDto,
} from './dto/reception.dto';

type Db = Prisma.TransactionClient;
type ReceptionWithLines = Reception & { lines: ReceptionLine[] };
type LockedOrder = Awaited<ReturnType<typeof PurchaseOrdersService.lockOrder>>;

const RECEPTION_INCLUDE = { lines: { orderBy: { id: 'asc' } } } as const;

/// Tris autorisés (liste blanche, CONVENTIONS.md).
const RECEPTION_SORT_FIELDS = ['receivedAt', 'number'] as const;

/// Statuts où une commande accepte encore de la marchandise. ANNULEE, BROUILLON
/// et COMMANDEE en sont exclus : on ne réceptionne que ce qui est engagé.
const RECEIVABLE = ['CONFIRMEE', 'PARTIELLEMENT_RECUE'];

/// Réceptions (P0 #7). Le stock augmente UNIQUEMENT des quantités réellement
/// reçues (règle 6) et la dette fournisseur augmente du TTC figé ici
/// (décision MEDMEDBEN 2026-09-16). Aucune suppression : une erreur se corrige
/// par un ajustement de stock, jamais en effaçant le bon (règle 7).
@Injectable()
export class ReceptionsService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly ledger: StockLedgerService,
  ) {}

  async create(
    dto: CreateReceptionDto,
    user: AuthenticatedUser,
    actor: ActorContext,
  ): Promise<ReceptionDto> {
    return runOnce(
      () => this.replay(dto, user),
      () =>
        this.prisma.$transaction(async (tx) => {
          const supplier = await tx.supplier.findFirst({
            where: { id: dto.supplierId, isActive: true },
          });
          if (!supplier) {
            throw new BusinessException(
              ErrorCode.VALIDATION_FAILED,
              'supplierId : fournisseur introuvable ou désactivé',
              HttpStatus.UNPROCESSABLE_ENTITY,
            );
          }

          // MÊME verrou que l'annulation et la modification de commande : une
          // annulation et une réception simultanées ne peuvent pas passer
          // toutes les deux, la seconde voit l'état laissé par la première.
          const order = dto.purchaseOrderId
            ? await PurchaseOrdersService.lockOrder(tx, dto.purchaseOrderId)
            : null;
          if (order) {
            if (order.supplierId !== supplier.id) {
              throw new BusinessException(
                ErrorCode.VALIDATION_FAILED,
                `Commande ${order.number} : elle appartient à un autre fournisseur`,
                HttpStatus.UNPROCESSABLE_ENTITY,
              );
            }
            if (!RECEIVABLE.includes(order.status)) {
              throw new BusinessException(
                ErrorCode.INVALID_STATE_TRANSITION,
                `Commande ${order.status.toLowerCase().replace(/_/g, ' ')} : aucune réception possible`,
                HttpStatus.CONFLICT,
              );
            }
          }

          const lines = await this.buildLines(tx, dto, order);
          const number = await nextDocumentNumber(tx, 'RECEPTION', 'BR', 5);
          const reception = await tx.reception.create({
            include: RECEPTION_INCLUDE,
            data: {
              id: dto.id,
              number,
              clientMutationId: dto.clientMutationId,
              purchaseOrderId: order?.id ?? null,
              supplierId: supplier.id,
              locationId: dto.locationId,
              userId: user.id,
              note: dto.note ?? null,
              lines: { create: lines },
            },
          });

          // Règle 2 : le stock n'entre que par le journal. Ordre fixe par
          // produit pour ne pas interbloquer deux réceptions concurrentes.
          for (const line of [...reception.lines].sort((a, b) =>
            a.productId.localeCompare(b.productId),
          )) {
            await this.ledger.applyMovement(tx, {
              productId: line.productId,
              locationId: reception.locationId,
              quantity: line.receivedQuantity,
              type: 'RECEPTION',
              operationType: 'RECEPTION',
              operationId: reception.id,
              userId: user.id,
              comment: reception.number,
            });
            // Règle 5 : le coût du produit = DERNIER prix d'achat réceptionné.
            await tx.product.update({
              where: { id: line.productId },
              data: { lastPurchasePriceHt: line.unitPriceHt },
            });
          }

          if (order) await ReceptionsService.applyToOrder(tx, order.id, lines);

          await writeAudit(tx, actor, {
            action: 'CREATE',
            entityType: 'Reception',
            entityId: reception.id,
            newValue: {
              number: reception.number,
              purchaseOrderId: reception.purchaseOrderId,
              supplierId: reception.supplierId,
              locationId: reception.locationId,
              totalTtc: ReceptionsService.totalTtc(reception.lines),
              lines: reception.lines.map((l) => ({
                productId: l.productId,
                receivedQuantity: formatQuantity(l.receivedQuantity),
                unitPriceHt: l.unitPriceHt,
              })),
            },
          });
          return ReceptionsService.toDto(reception);
        }),
    );
  }

  async findAll(query: ReceptionListQueryDto): Promise<ReceptionListDto> {
    const where: Prisma.ReceptionWhereInput = {
      ...(query.supplierId && { supplierId: query.supplierId }),
      ...(query.purchaseOrderId && { purchaseOrderId: query.purchaseOrderId }),
    };
    const [rows, total] = await Promise.all([
      this.prisma.reception.findMany({
        where,
        include: RECEPTION_INCLUDE,
        skip: (query.page - 1) * query.limit,
        take: query.limit,
        orderBy: [
          parseSort(query.sort, RECEPTION_SORT_FIELDS, { receivedAt: 'desc' }),
          { id: 'desc' },
        ],
      }),
      this.prisma.reception.count({ where }),
    ]);
    return {
      data: rows.map(ReceptionsService.toDto),
      meta: { page: query.page, limit: query.limit, total },
    };
  }

  async findOne(id: string): Promise<ReceptionDto> {
    const reception = await this.prisma.reception.findUnique({
      where: { id },
      include: RECEPTION_INCLUDE,
    });
    if (!reception) {
      throw new BusinessException(
        ErrorCode.NOT_FOUND,
        'Réception introuvable',
        HttpStatus.NOT_FOUND,
      );
    }
    return ReceptionsService.toDto(reception);
  }

  /// Renvoi de la même réception (réponse perdue, double clic) : on rend celle
  /// déjà enregistrée, sans faire entrer la marchandise une seconde fois.
  private async replay(
    dto: CreateReceptionDto,
    user: AuthenticatedUser,
  ): Promise<ReceptionDto | null> {
    const existing = await this.prisma.reception.findUnique({
      where: { clientMutationId: dto.clientMutationId },
      include: RECEPTION_INCLUDE,
    });
    if (!existing) return null;
    assertSameMutation(
      existing,
      user.id,
      ReceptionsService.contentKey(existing) === ReceptionsService.dtoKey(dto),
      {
        code: ErrorCode.CONFLICT,
        message: `Réception déjà enregistrée (${existing.number}) avec un autre contenu`,
      },
    );
    return ReceptionsService.toDto(existing);
  }

  /// Lignes validées : produit connu, quantité > 0, et surtout **surlivraison
  /// refusée** — on ne reçoit jamais plus que le reste à recevoir d'une ligne
  /// de commande (décision MEDMEDBEN 2026-09-16 : le magasinier fait d'abord
  /// modifier la commande).
  private async buildLines(
    tx: Db,
    dto: CreateReceptionDto,
    order: LockedOrder | null,
  ) {
    const products = await tx.product.findMany({
      where: { id: { in: dto.lines.map((l) => l.productId) } },
      include: { taxRate: true },
    });
    // Cumul par ligne de commande : deux lignes du même bon visant la même
    // ligne de commande ne doivent pas dépasser le reste à elles deux.
    const asked = new Map<string, Prisma.Decimal>();
    const built = dto.lines.map((line) => {
      const product = products.find((p) => p.id === line.productId);
      if (!product) {
        throw new BusinessException(
          ErrorCode.VALIDATION_FAILED,
          'lines.productId : produit introuvable',
          HttpStatus.UNPROCESSABLE_ENTITY,
        );
      }
      const quantity = parseQuantity(
        line.receivedQuantity,
        'lines.receivedQuantity',
      );
      if (quantity.lessThanOrEqualTo(0)) {
        throw new BusinessException(
          ErrorCode.VALIDATION_FAILED,
          'lines.receivedQuantity : quantité strictement positive attendue',
          HttpStatus.UNPROCESSABLE_ENTITY,
        );
      }
      let taxRate = product.taxRate?.rate ?? new Prisma.Decimal(0);
      if (line.purchaseLineId) {
        const ordered = order?.lines.find((l) => l.id === line.purchaseLineId);
        if (!ordered) {
          throw new BusinessException(
            ErrorCode.VALIDATION_FAILED,
            'lines.purchaseLineId : ligne absente de cette commande',
            HttpStatus.UNPROCESSABLE_ENTITY,
          );
        }
        if (ordered.productId !== product.id) {
          throw new BusinessException(
            ErrorCode.VALIDATION_FAILED,
            'lines.purchaseLineId : cette ligne de commande porte un autre produit',
            HttpStatus.UNPROCESSABLE_ENTITY,
          );
        }
        // TVA figée à la COMMANDE : c'est le taux négocié, pas celui du jour.
        taxRate = ordered.taxRate;
        const cumulated = (asked.get(ordered.id) ?? new Prisma.Decimal(0)).add(
          quantity,
        );
        const remaining = ordered.orderedQuantity.sub(ordered.receivedQuantity);
        if (cumulated.greaterThan(remaining)) {
          throw new BusinessException(
            ErrorCode.VALIDATION_FAILED,
            `Surlivraison refusée : reste à recevoir ${formatQuantity(remaining)}, ` +
              `reçu annoncé ${formatQuantity(cumulated)} — faites modifier la commande`,
            HttpStatus.UNPROCESSABLE_ENTITY,
          );
        }
        asked.set(ordered.id, cumulated);
      } else if (order) {
        throw new BusinessException(
          ErrorCode.VALIDATION_FAILED,
          'lines.purchaseLineId : obligatoire sur une réception rattachée à une commande',
          HttpStatus.UNPROCESSABLE_ENTITY,
        );
      }
      const lineTotalHt = ReceptionsService.round(
        quantity.mul(line.unitPriceHt),
      );
      const lineTotalTtc =
        lineTotalHt +
        ReceptionsService.round(
          new Prisma.Decimal(lineTotalHt).mul(taxRate).div(100),
        );
      return {
        productId: product.id,
        purchaseLineId: line.purchaseLineId ?? null,
        receivedQuantity: quantity,
        unitPriceHt: line.unitPriceHt,
        lineTotalTtc,
      };
    });
    if (ReceptionsService.totalTtc(built) > MAX_MONEY) {
      throw new BusinessException(
        ErrorCode.VALIDATION_FAILED,
        'Montant de la réception trop élevé',
        HttpStatus.UNPROCESSABLE_ENTITY,
      );
    }
    return built;
  }

  /// Reporte les quantités reçues sur la commande et fait suivre son statut :
  /// tout reçu → RECUE, sinon PARTIELLEMENT_RECUE (règle 6).
  private static async applyToOrder(
    tx: Db,
    orderId: string,
    lines: {
      purchaseLineId: string | null;
      receivedQuantity: Prisma.Decimal;
    }[],
  ) {
    for (const line of lines) {
      if (!line.purchaseLineId) continue;
      await tx.purchaseLine.update({
        where: { id: line.purchaseLineId },
        data: { receivedQuantity: { increment: line.receivedQuantity } },
      });
    }
    const after = await tx.purchaseLine.findMany({
      where: { purchaseOrderId: orderId },
    });
    const complete = after.every((l) =>
      l.receivedQuantity.greaterThanOrEqualTo(l.orderedQuantity),
    );
    await tx.purchaseOrder.update({
      where: { id: orderId },
      data: { status: complete ? 'RECUE' : 'PARTIELLEMENT_RECUE' },
    });
  }

  private static round(value: Prisma.Decimal): number {
    return value.toDecimalPlaces(0, Prisma.Decimal.ROUND_HALF_UP).toNumber();
  }

  private static totalTtc(lines: { lineTotalTtc: number }[]): number {
    return lines.reduce((sum, l) => sum + l.lineTotalTtc, 0);
  }

  private static contentKey(reception: ReceptionWithLines): string {
    return ReceptionsService.key(
      reception.supplierId,
      reception.locationId,
      reception.purchaseOrderId,
      reception.lines.map((l) => [
        l.productId,
        formatQuantity(l.receivedQuantity),
        l.unitPriceHt,
      ]),
    );
  }

  private static dtoKey(dto: CreateReceptionDto): string {
    return ReceptionsService.key(
      dto.supplierId,
      dto.locationId,
      dto.purchaseOrderId ?? null,
      dto.lines.map((l) => [
        l.productId,
        formatQuantity(
          parseQuantity(l.receivedQuantity, 'lines.receivedQuantity'),
        ),
        l.unitPriceHt,
      ]),
    );
  }

  private static key(
    supplierId: string,
    locationId: string,
    purchaseOrderId: string | null,
    lines: [string, string, number][],
  ): string {
    return [
      supplierId,
      locationId,
      purchaseOrderId ?? '',
      ...lines.map((l) => l.join('|')).sort(),
    ].join(';');
  }

  private static toDto(reception: ReceptionWithLines): ReceptionDto {
    return {
      id: reception.id,
      number: reception.number,
      purchaseOrderId: reception.purchaseOrderId,
      supplierId: reception.supplierId,
      locationId: reception.locationId,
      userId: reception.userId,
      receivedAt: reception.receivedAt,
      note: reception.note,
      totalTtc: ReceptionsService.totalTtc(reception.lines),
      lines: reception.lines.map((line) => ({
        id: line.id,
        productId: line.productId,
        purchaseLineId: line.purchaseLineId,
        receivedQuantity: formatQuantity(line.receivedQuantity),
        unitPriceHt: line.unitPriceHt,
        lineTotalHt: ReceptionsService.round(
          line.receivedQuantity.mul(line.unitPriceHt),
        ),
        lineTotalTtc: line.lineTotalTtc,
      })),
    };
  }
}
