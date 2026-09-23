import { HttpStatus, Injectable } from '@nestjs/common';
import { ActorContext, writeAudit } from '../audit/audit-writer';
import { AuthenticatedUser } from '../common/auth.decorators';
import { parseApiDate } from '../common/api-date';
import { BusinessException } from '../common/business.exception';
import { nextDocumentNumber } from '../common/document-number';
import { ErrorCode } from '../common/error-codes';
import { formatQuantity, parseQuantity } from '../common/quantity';
import {
  Prisma,
  PurchaseLine,
  PurchaseOrder,
} from '../generated/prisma/client';
import { parseSort } from '../common/dto/pagination.dto';
import {
  NOTIFY_DEPOT,
  NotificationsService,
} from '../notifications/notifications.service';
import { PrismaService } from '../prisma/prisma.service';
import { MAX_MONEY } from '../sales/dto/sale.dto';
import {
  ClosePurchaseOrderDto,
  ConfirmPurchaseOrderDto,
  CreatePurchaseOrderDto,
  PurchaseLineInputDto,
  PurchaseOrderDto,
  PurchaseOrderListDto,
  PurchaseOrderListQueryDto,
  UpdatePurchaseOrderDto,
} from './dto/purchase-order.dto';

type Db = Prisma.TransactionClient;

/// Tris autorisés (liste blanche, CONVENTIONS.md).
const ORDER_SORT_FIELDS = [
  'orderDate',
  'totalTtc',
  'number',
  'status',
] as const;
type OrderWithLines = PurchaseOrder & { lines: PurchaseLine[] };

const ORDER_INCLUDE = { lines: { orderBy: { id: 'asc' } } } as const;

/// Statuts où la commande est encore modifiable (rien n'est reçu, rien n'est
/// engagé) — au-delà, seule une annulation reste possible.
const EDITABLE = ['BROUILLON', 'COMMANDEE'];

@Injectable()
export class PurchaseOrdersService {
  constructor(private readonly prisma: PrismaService) {}

  async create(
    dto: CreatePurchaseOrderDto,
    user: AuthenticatedUser,
    actor: ActorContext,
  ): Promise<PurchaseOrderDto> {
    // Renvoi de la même commande (réponse perdue) : on rend celle déjà créée.
    if (dto.id) {
      const existing = await this.prisma.purchaseOrder.findUnique({
        where: { id: dto.id },
        include: ORDER_INCLUDE,
      });
      if (existing) {
        if (existing.createdById !== user.id) {
          throw new BusinessException(
            ErrorCode.CONFLICT,
            'Cet identifiant de commande est déjà utilisé',
            HttpStatus.CONFLICT,
          );
        }
        const key = (productId: string, quantity: string, price: number) =>
          `${productId}|${quantity}|${price}`;
        const same =
          existing.supplierId === dto.supplierId &&
          [
            ...existing.lines.map((l) =>
              key(
                l.productId,
                formatQuantity(l.orderedQuantity),
                l.unitPriceHt,
              ),
            ),
          ]
            .sort()
            .join(';') ===
            dto.lines
              .map((l) =>
                key(
                  l.productId,
                  formatQuantity(
                    parseQuantity(l.orderedQuantity, 'lines.orderedQuantity'),
                  ),
                  l.unitPriceHt,
                ),
              )
              .sort()
              .join(';');
        if (!same) {
          throw new BusinessException(
            ErrorCode.CONFLICT,
            `Commande déjà enregistrée (${existing.number}) avec un autre contenu`,
            HttpStatus.CONFLICT,
          );
        }
        return PurchaseOrdersService.toDto(existing);
      }
    }
    return this.prisma.$transaction(async (tx) => {
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
      const lines = await PurchaseOrdersService.buildLines(tx, dto.lines);
      const number = await nextDocumentNumber(tx, 'BON_COMMANDE', 'BC', 5);
      const order = await tx.purchaseOrder.create({
        include: ORDER_INCLUDE,
        data: {
          id: dto.id,
          number,
          supplierId: supplier.id,
          createdById: user.id,
          expectedDate: dto.expectedDate
            ? parseApiDate(dto.expectedDate, 'expectedDate')
            : null,
          dueDate: dto.dueDate ? parseApiDate(dto.dueDate, 'dueDate') : null,
          note: dto.note ?? null,
          ...PurchaseOrdersService.totals(lines),
          lines: { create: lines },
        },
      });
      await writeAudit(tx, actor, {
        action: 'CREATE',
        entityType: 'PurchaseOrder',
        entityId: order.id,
        newValue: {
          number: order.number,
          supplierId: order.supplierId,
          totalTtc: order.totalTtc,
        },
      });
      return PurchaseOrdersService.toDto(order);
    });
  }

  async findAll(
    query: PurchaseOrderListQueryDto,
  ): Promise<PurchaseOrderListDto> {
    const where: Prisma.PurchaseOrderWhereInput = {
      ...(query.supplierId && { supplierId: query.supplierId }),
      ...(query.status && { status: query.status }),
    };
    const [rows, total] = await Promise.all([
      this.prisma.purchaseOrder.findMany({
        where,
        include: ORDER_INCLUDE,
        skip: (query.page - 1) * query.limit,
        take: query.limit,
        orderBy: [
          parseSort(query.sort, ORDER_SORT_FIELDS, { orderDate: 'desc' }),
          { id: 'desc' },
        ],
      }),
      this.prisma.purchaseOrder.count({ where }),
    ]);
    return {
      data: rows.map(PurchaseOrdersService.toDto),
      meta: { page: query.page, limit: query.limit, total },
    };
  }

  async findOne(id: string): Promise<PurchaseOrderDto> {
    const order = await this.prisma.purchaseOrder.findUnique({
      where: { id },
      include: ORDER_INCLUDE,
    });
    if (!order) throw PurchaseOrdersService.notFound();
    return PurchaseOrdersService.toDto(order);
  }

  /// Modification tant que rien n'est reçu ni confirmé : les lignes envoyées
  /// remplacent les précédentes, les totaux sont recalculés.
  async update(
    id: string,
    dto: UpdatePurchaseOrderDto,
    actor: ActorContext,
  ): Promise<PurchaseOrderDto> {
    return this.prisma.$transaction(async (tx) => {
      const before = await PurchaseOrdersService.lockOrder(tx, id);
      if (!EDITABLE.includes(before.status)) {
        throw new BusinessException(
          ErrorCode.INVALID_STATE_TRANSITION,
          `Commande ${before.status.toLowerCase()} : elle ne se modifie plus`,
          HttpStatus.CONFLICT,
        );
      }
      if (await tx.reception.count({ where: { purchaseOrderId: id } })) {
        throw new BusinessException(
          ErrorCode.INVALID_STATE_TRANSITION,
          'Des réceptions existent sur cette commande : elle ne se modifie plus',
          HttpStatus.CONFLICT,
        );
      }
      if (dto.status === 'COMMANDEE' && before.status !== 'BROUILLON') {
        throw new BusinessException(
          ErrorCode.INVALID_STATE_TRANSITION,
          'Seul un brouillon peut être marqué comme envoyé',
          HttpStatus.CONFLICT,
        );
      }
      const lines = dto.lines
        ? await PurchaseOrdersService.buildLines(tx, dto.lines)
        : null;
      if (lines) {
        await tx.purchaseLine.deleteMany({ where: { purchaseOrderId: id } });
      }
      const order = await tx.purchaseOrder.update({
        where: { id },
        include: ORDER_INCLUDE,
        data: {
          ...(dto.expectedDate !== undefined && {
            expectedDate: dto.expectedDate
              ? parseApiDate(dto.expectedDate, 'expectedDate')
              : null,
          }),
          ...(dto.dueDate !== undefined && {
            dueDate: dto.dueDate ? parseApiDate(dto.dueDate, 'dueDate') : null,
          }),
          ...(dto.note !== undefined && { note: dto.note }),
          ...(dto.status !== undefined && { status: dto.status }),
          ...(lines && {
            lines: { create: lines },
            ...PurchaseOrdersService.totals(lines),
          }),
        },
      });
      await writeAudit(tx, actor, {
        action: 'UPDATE',
        entityType: 'PurchaseOrder',
        entityId: id,
        oldValue: PurchaseOrdersService.snapshot(before),
        newValue: PurchaseOrdersService.snapshot(order),
      });
      return PurchaseOrdersService.toDto(order);
    });
  }

  /// Confirmation (ADMIN seul) : la commande est engagée chez le fournisseur.
  /// La DETTE, elle, ne bouge qu'à la RÉCEPTION (décision MEDMEDBEN 2026-09-16).
  async confirm(
    id: string,
    dto: ConfirmPurchaseOrderDto,
    user: AuthenticatedUser,
    actor: ActorContext,
  ): Promise<PurchaseOrderDto> {
    return this.prisma.$transaction(async (tx) => {
      const before = await PurchaseOrdersService.lockOrder(tx, id);
      if (before.status === 'CONFIRMEE') {
        return PurchaseOrdersService.toDto(before);
      }
      // Séparation « le magasinier prépare, l'admin confirme » : la version
      // confirmée est EXACTEMENT celle que l'admin a eue sous les yeux.
      if (
        before.updatedAt.getTime() !== new Date(dto.expectedUpdatedAt).getTime()
      ) {
        throw new BusinessException(
          ErrorCode.CONFLICT,
          'La commande a été modifiée entre-temps : relisez-la avant de confirmer',
          HttpStatus.CONFLICT,
        );
      }
      if (!EDITABLE.includes(before.status)) {
        throw new BusinessException(
          ErrorCode.INVALID_STATE_TRANSITION,
          `Commande ${before.status.toLowerCase()} : confirmation impossible`,
          HttpStatus.CONFLICT,
        );
      }
      const order = await tx.purchaseOrder.update({
        where: { id },
        include: ORDER_INCLUDE,
        data: {
          status: 'CONFIRMEE',
          confirmedById: user.id,
          confirmedAt: new Date(),
        },
      });
      await writeAudit(tx, actor, {
        action: 'VALIDATE',
        entityType: 'PurchaseOrder',
        entityId: id,
        oldValue: { status: before.status },
        newValue: PurchaseOrdersService.snapshot(order),
      });
      // Confirmer est réservé à l'admin : sans cette alerte, le magasinier qui
      // réceptionnera n'apprend par aucun canal qu'une livraison est engagée.
      // Aucun montant dans le message — le lien ramène à la commande.
      await NotificationsService.notifyRoles(
        tx,
        NOTIFY_DEPOT,
        {
          type: 'COMMANDE_CONFIRMEE',
          title: `Commande ${order.number} confirmée`,
          body: `${order.lines.length} ligne(s) à recevoir.`,
          operationType: 'PURCHASE_ORDER',
          operationId: order.id,
        },
        user.id,
      );
      return PurchaseOrdersService.toDto(order);
    });
  }

  /// Annulation (ADMIN seul) : pas de suppression (règle 7). Refusée dès qu'une
  /// réception existe — la marchandise est entrée en stock.
  async cancel(id: string, actor: ActorContext): Promise<PurchaseOrderDto> {
    return this.prisma.$transaction(async (tx) => {
      const before = await PurchaseOrdersService.lockOrder(tx, id);
      if (before.status === 'ANNULEE') {
        throw new BusinessException(
          ErrorCode.INVALID_STATE_TRANSITION,
          'Commande déjà annulée',
          HttpStatus.CONFLICT,
        );
      }
      const received = await tx.reception.count({
        where: { purchaseOrderId: id },
      });
      if (received > 0) {
        throw new BusinessException(
          ErrorCode.INVALID_STATE_TRANSITION,
          'Des réceptions existent sur cette commande : annulation impossible',
          HttpStatus.CONFLICT,
        );
      }
      const order = await tx.purchaseOrder.update({
        where: { id },
        include: ORDER_INCLUDE,
        data: { status: 'ANNULEE', cancelledAt: new Date() },
      });
      await writeAudit(tx, actor, {
        action: 'CANCEL',
        entityType: 'PurchaseOrder',
        entityId: id,
        oldValue: { status: before.status },
        newValue: { status: 'ANNULEE' },
      });
      return PurchaseOrdersService.toDto(order);
    });
  }

  /// Clôture du reliquat (ADMIN seul) : le fournisseur ne livrera pas le reste.
  /// Sans elle, une commande partiellement reçue reste ouverte à vie — elle ne
  /// se modifie plus (des réceptions existent), ne s'annule plus (la
  /// marchandise est entrée) et n'atteindra jamais RECUE.
  async close(
    id: string,
    dto: ClosePurchaseOrderDto,
    actor: ActorContext,
  ): Promise<PurchaseOrderDto> {
    return this.prisma.$transaction(async (tx) => {
      const before = await PurchaseOrdersService.lockOrder(tx, id);
      if (before.status !== 'PARTIELLEMENT_RECUE') {
        throw new BusinessException(
          ErrorCode.INVALID_STATE_TRANSITION,
          'Seule une commande partiellement reçue se clôture : une commande ' +
            'sans réception s’annule, une commande soldée est déjà close',
          HttpStatus.CONFLICT,
        );
      }
      const order = await tx.purchaseOrder.update({
        where: { id },
        include: ORDER_INCLUDE,
        data: {
          status: 'CLOTUREE',
          closedAt: new Date(),
          closedReason: dto.reason,
        },
      });
      await writeAudit(tx, actor, {
        action: 'CLOSE',
        entityType: 'PurchaseOrder',
        entityId: id,
        oldValue: {
          status: before.status,
          reliquat: before.lines.map((l) => ({
            productId: l.productId,
            remaining: formatQuantity(
              l.orderedQuantity.sub(l.receivedQuantity),
            ),
          })),
        },
        newValue: { status: 'CLOTUREE', closedReason: dto.reason },
      });
      return PurchaseOrdersService.toDto(order);
    });
  }

  /// Verrou de ligne : deux écritures simultanées sur la MÊME commande
  /// (confirmation, annulation, modification, réception) s'exécutent l'une après
  /// l'autre, jamais en parallèle. Point d'entrée unique, partagé avec les
  /// réceptions — c'est lui qui empêche « annuler » et « réceptionner » de
  /// passer tous les deux.
  static async lockOrder(tx: Db, id: string): Promise<OrderWithLines> {
    await tx.$queryRaw`SELECT "id" FROM "PurchaseOrder" WHERE "id" = ${id}::uuid FOR UPDATE`;
    const order = await tx.purchaseOrder.findUnique({
      where: { id },
      include: ORDER_INCLUDE,
    });
    if (!order) throw PurchaseOrdersService.notFound();
    return order;
  }

  /// Lignes validées : produit actif, quantité > 0, TVA figée à la commande.
  private static async buildLines(tx: Db, input: PurchaseLineInputDto[]) {
    const products = await tx.product.findMany({
      where: { id: { in: input.map((l) => l.productId) }, isActive: true },
      include: { taxRate: true },
    });
    return input.map((line) => {
      const product = products.find((p) => p.id === line.productId);
      if (!product) {
        throw new BusinessException(
          ErrorCode.VALIDATION_FAILED,
          'lines.productId : produit introuvable ou désactivé',
          HttpStatus.UNPROCESSABLE_ENTITY,
        );
      }
      const quantity = parseQuantity(
        line.orderedQuantity,
        'lines.orderedQuantity',
      );
      if (quantity.lessThanOrEqualTo(0)) {
        throw new BusinessException(
          ErrorCode.VALIDATION_FAILED,
          'lines.orderedQuantity : quantité strictement positive attendue',
          HttpStatus.UNPROCESSABLE_ENTITY,
        );
      }
      return {
        productId: product.id,
        orderedQuantity: quantity,
        unitPriceHt: line.unitPriceHt,
        taxRate: product.taxRate?.rate ?? new Prisma.Decimal(0),
      };
    });
  }

  /// Totaux HT / TVA / TTC, en centimes entiers (règle 4).
  private static totals(
    lines: {
      orderedQuantity: Prisma.Decimal;
      unitPriceHt: number;
      taxRate: Prisma.Decimal;
    }[],
  ) {
    let totalHt = 0;
    let totalTax = 0;
    for (const line of lines) {
      const ht = PurchaseOrdersService.lineHt(line);
      totalHt += ht;
      totalTax += PurchaseOrdersService.round(
        new Prisma.Decimal(ht).mul(line.taxRate).div(100),
      );
    }
    const totalTtc = totalHt + totalTax;
    if (totalTtc > MAX_MONEY) {
      throw new BusinessException(
        ErrorCode.VALIDATION_FAILED,
        'Montant de la commande trop élevé',
        HttpStatus.UNPROCESSABLE_ENTITY,
      );
    }
    return { totalHt, totalTax, totalTtc };
  }

  private static lineHt(line: {
    orderedQuantity: Prisma.Decimal;
    unitPriceHt: number;
  }) {
    return PurchaseOrdersService.round(
      line.orderedQuantity.mul(line.unitPriceHt),
    );
  }

  private static round(value: Prisma.Decimal): number {
    return value.toDecimalPlaces(0, Prisma.Decimal.ROUND_HALF_UP).toNumber();
  }

  /// Contenu tracé à l'audit : ce qui engage l'argent (lignes, prix) et les
  /// dates — un échange de prix à total égal doit rester visible.
  private static snapshot(order: OrderWithLines) {
    return {
      status: order.status,
      totalTtc: order.totalTtc,
      expectedDate: order.expectedDate,
      dueDate: order.dueDate,
      note: order.note,
      lines: order.lines.map((l) => ({
        productId: l.productId,
        orderedQuantity: formatQuantity(l.orderedQuantity),
        unitPriceHt: l.unitPriceHt,
        taxRate: l.taxRate.toFixed(2),
      })),
    };
  }

  private static notFound() {
    return new BusinessException(
      ErrorCode.NOT_FOUND,
      'Commande introuvable',
      HttpStatus.NOT_FOUND,
    );
  }

  private static toDto(order: OrderWithLines): PurchaseOrderDto {
    return {
      id: order.id,
      number: order.number,
      supplierId: order.supplierId,
      status: order.status,
      createdById: order.createdById,
      confirmedById: order.confirmedById,
      orderDate: order.orderDate,
      expectedDate: order.expectedDate,
      dueDate: order.dueDate,
      confirmedAt: order.confirmedAt,
      cancelledAt: order.cancelledAt,
      closedAt: order.closedAt,
      closedReason: order.closedReason,
      totalHt: order.totalHt,
      totalTax: order.totalTax,
      totalTtc: order.totalTtc,
      note: order.note,
      updatedAt: order.updatedAt,
      lines: order.lines.map((line) => {
        const lineTotalHt = PurchaseOrdersService.lineHt(line);
        const lineTax = PurchaseOrdersService.round(
          new Prisma.Decimal(lineTotalHt).mul(line.taxRate).div(100),
        );
        return {
          id: line.id,
          productId: line.productId,
          orderedQuantity: formatQuantity(line.orderedQuantity),
          receivedQuantity: formatQuantity(line.receivedQuantity),
          remainingQuantity: formatQuantity(
            line.orderedQuantity.sub(line.receivedQuantity),
          ),
          unitPriceHt: line.unitPriceHt,
          taxRate: line.taxRate.toFixed(2),
          lineTotalHt,
          lineTotalTtc: lineTotalHt + lineTax,
        };
      }),
    };
  }
}
