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
          // Hors commande, la réception EST un achat : elle crée du stock, de
          // la dette et un coût d'achat sans qu'aucun admin ait engagé quoi que
          // ce soit. Réservée à l'ADMIN (audit sécurité du 2026-09-20).
          if (!order && !user.roles.includes('ADMIN')) {
            throw new BusinessException(
              ErrorCode.FORBIDDEN_ROLE,
              'Réception hors commande réservée à l’administrateur : ' +
                'créez la commande, faites-la confirmer, puis réceptionnez',
              HttpStatus.FORBIDDEN,
            );
          }
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

          // La marchandise entre au MAGASIN ou au DÉPÔT, jamais au TRANSIT
          // (qui ne porte que du stock déjà parti) : sans cette borne, une
          // réception au transit y gèlerait du stock, aucune perte ne s'y
          // déclarant. Même garde que le stock initial d'un produit et que la
          // déclaration de perte (CONVENTIONS, règle 1 : un invariant vaut pour
          // tous les chemins).
          const destination = await tx.location.findUnique({
            where: { id: dto.locationId },
            select: { type: true },
          });
          if (
            destination?.type !== 'MAGASIN' &&
            destination?.type !== 'DEPOT'
          ) {
            throw new BusinessException(
              ErrorCode.VALIDATION_FAILED,
              'locationId : la marchandise se réceptionne au magasin ou au dépôt',
              HttpStatus.UNPROCESSABLE_ENTITY,
            );
          }

          const lines = await this.buildLines(tx, dto, order);
          const totalTtc = ReceptionsService.totalTtc(lines);
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
              totalTtc,
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
          }
          // Règle 5 : le coût = DERNIER prix réceptionné. Parcouru dans l'ordre
          // DU BON (et non dans l'ordre de verrouillage) : si un produit revient
          // sur deux lignes, c'est la dernière qui fixe le coût, pas le hasard.
          for (const line of reception.lines) {
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
              totalTtc: reception.totalTtc,
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
      let unitPriceHt = line.unitPriceHt;
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
        // Prix ET TVA figés à la COMMANDE : c'est ce que l'admin a engagé en
        // la confirmant. Le magasinier constate ce qui arrive, il ne rouvre pas
        // la négociation (audit sécurité du 2026-09-20).
        taxRate = ordered.taxRate;
        unitPriceHt = ordered.unitPriceHt;
        const cumulated = (asked.get(ordered.id) ?? new Prisma.Decimal(0)).add(
          quantity,
        );
        const remaining = ordered.orderedQuantity.sub(ordered.receivedQuantity);
        if (cumulated.greaterThan(remaining)) {
          throw new BusinessException(
            ErrorCode.VALIDATION_FAILED,
            `Surlivraison refusée : reste à recevoir ${formatQuantity(remaining)}, ` +
              `reçu annoncé ${formatQuantity(cumulated)} — le surplus fait l’objet ` +
              'd’une réception hors commande (administrateur)',
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
      const lineTotalHt = ReceptionsService.round(quantity.mul(unitPriceHt));
      const lineTotalTtc =
        lineTotalHt +
        ReceptionsService.round(
          new Prisma.Decimal(lineTotalHt).mul(taxRate).div(100),
        );
      return {
        productId: product.id,
        purchaseLineId: line.purchaseLineId ?? null,
        receivedQuantity: quantity,
        unitPriceHt,
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

  /// Empreinte du CONTENU d'une réception : deux envois de même empreinte sont
  /// le même bon. Le prix n'y figure pas — il vient de la commande, pas du
  /// client. La ligne de commande visée, elle, y figure : deux bons identiques
  /// sur des lignes différentes ne sont pas le même bon.
  private static key(reception: {
    supplierId: string;
    locationId: string;
    purchaseOrderId: string | null;
    note: string | null;
    lines: {
      productId: string;
      purchaseLineId: string | null;
      quantity: string;
    }[];
  }): string {
    return [
      reception.supplierId,
      reception.locationId,
      reception.purchaseOrderId ?? '',
      reception.note ?? '',
      ...reception.lines
        .map((l) => `${l.productId}|${l.purchaseLineId ?? ''}|${l.quantity}`)
        .sort(),
    ].join(';');
  }

  private static contentKey(reception: ReceptionWithLines): string {
    return ReceptionsService.key({
      supplierId: reception.supplierId,
      locationId: reception.locationId,
      purchaseOrderId: reception.purchaseOrderId,
      note: reception.note,
      lines: reception.lines.map((l) => ({
        productId: l.productId,
        purchaseLineId: l.purchaseLineId,
        quantity: formatQuantity(l.receivedQuantity),
      })),
    });
  }

  private static dtoKey(dto: CreateReceptionDto): string {
    return ReceptionsService.key({
      supplierId: dto.supplierId,
      locationId: dto.locationId,
      purchaseOrderId: dto.purchaseOrderId ?? null,
      note: dto.note ?? null,
      lines: dto.lines.map((l) => ({
        productId: l.productId,
        purchaseLineId: l.purchaseLineId ?? null,
        quantity: formatQuantity(
          parseQuantity(l.receivedQuantity, 'lines.receivedQuantity'),
        ),
      })),
    });
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
      totalTtc: reception.totalTtc,
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
