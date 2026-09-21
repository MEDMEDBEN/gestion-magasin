import { HttpStatus, Injectable } from '@nestjs/common';
import { ActorContext, writeAudit } from '../audit/audit-writer';
import { AuthenticatedUser } from '../common/auth.decorators';
import { BusinessException } from '../common/business.exception';
import { nextDocumentNumber } from '../common/document-number';
import { parseSort } from '../common/dto/pagination.dto';
import { ErrorCode } from '../common/error-codes';
import { assertSameMutation, runOnce } from '../common/idempotency';
import { formatQuantity, parseQuantity } from '../common/quantity';
import { Inventory, InventoryLine, Prisma } from '../generated/prisma/client';
import { InventoryStatus } from '../generated/prisma/enums';
import { PrismaService } from '../prisma/prisma.service';
import { StockLedgerService } from '../stock/stock-ledger.service';
import {
  CreateInventoryDto,
  InventoryDto,
  InventoryListDto,
  InventoryListQueryDto,
  InventoryTypeDto,
  SubmitCountDto,
} from './dto/inventory.dto';

type Db = Prisma.TransactionClient;
type InventoryWithLines = Inventory & { lines: InventoryLine[] };

const INVENTORY_INCLUDE = { lines: { orderBy: { id: 'asc' } } } as const;

/// Tris autorisés (liste blanche, CONVENTIONS.md).
const INVENTORY_SORT_FIELDS = ['startedAt', 'number'] as const;

/// Inventaire (P0 #9, spec §22) — « comparer théorique ↔ physique ».
///
/// Trois temps, et UN SEUL touche le stock :
/// 1. lancement : les lignes sont créées avec le stock du moment, pour servir
///    de feuille de comptage. Aucun mouvement.
/// 2. comptage : le compteur saisit le physique. Le théorique de la ligne est
///    alors RELU et REMPLACÉ — c'est ce que le système croyait quand on avait
///    le produit en main, donc le seul théorique honnête pour calculer l'écart.
///    (Le théorique du lancement n'est donc pas conservé ; il reste consultable
///    dans `AuditLog`, qui garde l'état à la création.) Aucun mouvement.
/// 3. validation (ADMIN SEUL, spec §22) : un mouvement `AJUSTEMENT_INVENTAIRE`
///    par écart, en DELTA (règle 2 : jamais une quantité absolue).
///
/// Parce que l'ajustement est un DELTA, une vente survenue entre le comptage et
/// la validation ne pose AUCUN problème : elle s'ajoute à l'écart au lieu d'être
/// écrasée. Le seul cas refusé est la double correction du même écart par deux
/// inventaires qui se chevauchent (voir `assertNotAlreadyAdjusted`).
@Injectable()
export class InventoryService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly ledger: StockLedgerService,
  ) {}

  async create(
    dto: CreateInventoryDto,
    user: AuthenticatedUser,
    actor: ActorContext,
  ): Promise<InventoryDto> {
    return runOnce(
      () => this.replay(dto, user),
      () =>
        this.prisma.$transaction(async (tx) => {
          const location = await tx.location.findUnique({
            where: { id: dto.locationId },
            select: { id: true, type: true, isActive: true },
          });
          // Le stock ne vit qu'au MAGASIN et au DÉPÔT : une position ou le
          // transit ne portent pas de projection à compter.
          if (
            !location?.isActive ||
            (location.type !== 'MAGASIN' && location.type !== 'DEPOT')
          ) {
            throw new BusinessException(
              ErrorCode.VALIDATION_FAILED,
              'locationId : on inventorie le magasin ou le dépôt',
              HttpStatus.UNPROCESSABLE_ENTITY,
            );
          }
          InventoryService.assertScope(dto);

          const lines = await InventoryService.buildLines(tx, dto);
          if (lines.length === 0) {
            throw new BusinessException(
              ErrorCode.VALIDATION_FAILED,
              'Rien à compter : aucun produit connu à cet emplacement',
              HttpStatus.UNPROCESSABLE_ENTITY,
            );
          }
          const number = await nextDocumentNumber(tx, 'INVENTAIRE', 'INV', 5);
          const inventory = await tx.inventory.create({
            include: INVENTORY_INCLUDE,
            data: {
              id: dto.id,
              number,
              clientMutationId: dto.clientMutationId,
              type: dto.type,
              locationId: location.id,
              zone: dto.zone ?? null,
              note: dto.note ?? null,
              createdById: user.id,
              lines: { create: lines },
            },
          });
          await writeAudit(tx, actor, {
            action: 'CREATE',
            entityType: 'Inventory',
            entityId: inventory.id,
            newValue: InventoryService.snapshot(inventory),
          });
          return InventoryService.toDto(inventory);
        }),
    );
  }

  /// Saisie du comptage physique. Reprenable : `done: false` garde l'inventaire
  /// EN_COURS, `done: true` le clôt (TERMINE) et ouvre la validation.
  /// AUCUN mouvement de stock ici.
  async submitCount(
    id: string,
    dto: SubmitCountDto,
    user: AuthenticatedUser,
    actor: ActorContext,
  ): Promise<InventoryDto> {
    return this.prisma.$transaction(async (tx) => {
      const before = await InventoryService.lockInventory(tx, id);
      if (before.status !== 'EN_COURS') {
        throw new BusinessException(
          ErrorCode.INVALID_STATE_TRANSITION,
          `Inventaire ${before.number} déjà terminé : il ne se recompte plus`,
          HttpStatus.CONFLICT,
        );
      }

      const counted = new Map<string, string>();
      for (const line of dto.lines) {
        if (counted.has(line.productId)) {
          throw new BusinessException(
            ErrorCode.VALIDATION_FAILED,
            'lines.productId : produit compté deux fois dans le même envoi',
            HttpStatus.UNPROCESSABLE_ENTITY,
          );
        }
        counted.set(line.productId, line.countedQuantity);
      }

      for (const line of before.lines) {
        const raw = counted.get(line.productId);
        // Ligne non citée : son comptage précédent (ou son absence) est gardé.
        if (raw === undefined) continue;
        const quantity = parseQuantity(raw, 'lines.countedQuantity');
        // Théorique RELU au moment du comptage : c'est ce que le système
        // croyait quand le compteur avait le produit en main.
        const theoretical = await InventoryService.currentStock(
          tx,
          line.productId,
          before.locationId,
        );
        const difference = quantity.sub(theoretical);
        await tx.inventoryLine.update({
          where: { id: line.id },
          data: {
            theoreticalQuantity: theoretical,
            countedQuantity: quantity,
            difference,
            state: difference.isZero() ? 'CONFORME' : 'ECART',
          },
        });
        counted.delete(line.productId);
      }
      if (counted.size > 0) {
        throw new BusinessException(
          ErrorCode.VALIDATION_FAILED,
          'lines.productId : produit absent de cet inventaire',
          HttpStatus.UNPROCESSABLE_ENTITY,
        );
      }

      const done = dto.done ?? false;
      // Un comptage ne se déclare terminé que s'il est COMPLET : sinon
      // l'inventaire partirait en validation avec des lignes jamais comptées,
      // et finirait « Ajusté » sans que personne ne les ait vues. Règle 1 :
      // c'est le SERVEUR qui la tient, l'écran n'en est que le miroir.
      if (done) {
        const missing = await tx.inventoryLine.count({
          where: { inventoryId: id, countedQuantity: null },
        });
        if (missing > 0) {
          throw new BusinessException(
            ErrorCode.VALIDATION_FAILED,
            `Comptage incomplet : ${missing} produit(s) sans quantité. ` +
              'Enregistrez-le en cours, ou complétez-le.',
            HttpStatus.UNPROCESSABLE_ENTITY,
          );
        }
      }
      const after = await tx.inventory.update({
        where: { id },
        include: INVENTORY_INCLUDE,
        data: done ? { status: 'TERMINE', completedAt: new Date() } : {},
      });
      await writeAudit(tx, actor, {
        action: 'UPDATE',
        entityType: 'Inventory',
        entityId: id,
        oldValue: InventoryService.snapshot(before),
        newValue: InventoryService.snapshot(after),
      });
      return InventoryService.toDto(after);
    });
  }

  /// Validation des ajustements — ADMIN SEUL (spec §22). Seule étape qui touche
  /// le stock, et une seule fois : rejouée, elle rend l'inventaire déjà validé.
  async validate(
    id: string,
    user: AuthenticatedUser,
    actor: ActorContext,
  ): Promise<InventoryDto> {
    return this.prisma.$transaction(async (tx) => {
      const before = await InventoryService.lockInventory(tx, id);
      if (before.validatedAt) return InventoryService.toDto(before);
      if (before.status !== 'TERMINE') {
        throw new BusinessException(
          ErrorCode.INVALID_STATE_TRANSITION,
          `Inventaire ${before.number} : terminez le comptage avant de valider`,
          HttpStatus.CONFLICT,
        );
      }

      const gaps = before.lines.filter(
        (line) => line.countedQuantity !== null && !line.difference.isZero(),
      );
      await InventoryService.assertNotAlreadyAdjusted(tx, before);

      // Règle 2 : le stock ne bouge que par le journal, en DELTA. Ordre fixe
      // par produit pour ne pas interbloquer deux validations concurrentes.
      for (const line of [...gaps].sort((a, b) =>
        a.productId.localeCompare(b.productId),
      )) {
        await this.ledger.applyMovement(tx, {
          productId: line.productId,
          locationId: before.locationId,
          quantity: line.difference,
          type: 'AJUSTEMENT_INVENTAIRE',
          operationType: 'INVENTORY',
          operationId: before.id,
          userId: user.id,
          comment: `${before.number} — écart constaté`,
        });
      }

      const after = await tx.inventory.update({
        where: { id },
        include: INVENTORY_INCLUDE,
        data: { validatedAt: new Date(), validatedById: user.id },
      });
      await writeAudit(tx, actor, {
        action: 'VALIDATE',
        entityType: 'Inventory',
        entityId: id,
        oldValue: InventoryService.snapshot(before),
        newValue: {
          ...(InventoryService.snapshot(after) as Record<string, unknown>),
          adjustedLines: gaps.length,
        },
      });
      return InventoryService.toDto(after);
    });
  }

  async findAll(query: InventoryListQueryDto): Promise<InventoryListDto> {
    const where: Prisma.InventoryWhereInput = InventoryService.statusFilter(
      query.status,
    );
    const [rows, total] = await Promise.all([
      this.prisma.inventory.findMany({
        where,
        include: INVENTORY_INCLUDE,
        skip: (query.page - 1) * query.limit,
        take: query.limit,
        orderBy: [
          parseSort(query.sort, INVENTORY_SORT_FIELDS, { startedAt: 'desc' }),
          { id: 'desc' },
        ],
      }),
      this.prisma.inventory.count({ where }),
    ]);
    return {
      data: rows.map(InventoryService.toDto),
      meta: { page: query.page, limit: query.limit, total },
    };
  }

  async findOne(id: string): Promise<InventoryDto> {
    const inventory = await this.prisma.inventory.findUnique({
      where: { id },
      include: INVENTORY_INCLUDE,
    });
    if (!inventory) throw InventoryService.notFound();
    return InventoryService.toDto(inventory);
  }

  /// Point d'entrée UNIQUE de toute écriture sur un inventaire (même rôle que
  /// `lockOrder` / `lockTransfer`) : le `FOR UPDATE` sérialise un comptage et
  /// une validation simultanés.
  static async lockInventory(tx: Db, id: string): Promise<InventoryWithLines> {
    await tx.$queryRaw`SELECT "id" FROM "Inventory" WHERE "id" = ${id}::uuid FOR UPDATE`;
    const inventory = await tx.inventory.findUnique({
      where: { id },
      include: INVENTORY_INCLUDE,
    });
    if (!inventory) throw InventoryService.notFound();
    return inventory;
  }

  /// Refuse une DOUBLE correction du même écart.
  ///
  /// Une vente ou une réception survenue depuis le comptage n'est PAS un
  /// problème : l'ajustement est un DELTA (règle 2). Théorique 50, compté 47
  /// → −3 ; une vente de 5 laisse le stock à 45 ; appliquer −3 donne 42, qui
  /// est la vérité physique (47 comptés − 5 vendus). Bloquer là-dessus rendrait
  /// l'inventaire invalidable sans rien protéger.
  ///
  /// Ce qui double-corrige vraiment, c'est un AUTRE ajustement d'inventaire sur
  /// le même produit et le même lieu depuis la clôture du comptage : deux
  /// inventaires qui se chevauchent ont lu le même théorique et appliqueraient
  /// deux fois le même écart. C'est le seul cas refusé ici.
  private static async assertNotAlreadyAdjusted(
    tx: Db,
    inventory: InventoryWithLines,
  ): Promise<void> {
    const since = inventory.completedAt;
    // `TERMINE` pose toujours `completedAt` (seul `submitCount` le fait), donc
    // ce cas est impossible — mais on refuse plutôt que de laisser passer une
    // validation dont on ne sait pas dater la référence (posture du projet).
    if (!since) {
      throw new BusinessException(
        ErrorCode.INVALID_STATE_TRANSITION,
        `Inventaire ${inventory.number} sans date de clôture de comptage`,
        HttpStatus.CONFLICT,
      );
    }
    const productIds = inventory.lines
      .filter((line) => line.countedQuantity !== null)
      .map((line) => line.productId);
    if (productIds.length === 0) return;

    const adjusted = await tx.stockMovement.findMany({
      where: {
        productId: { in: productIds },
        locationId: inventory.locationId,
        type: 'AJUSTEMENT_INVENTAIRE',
        operationType: 'INVENTORY',
        createdAt: { gt: since },
      },
      select: { productId: true },
      distinct: ['productId'],
    });
    if (adjusted.length === 0) return;

    const names = await tx.product.findMany({
      where: { id: { in: adjusted.map((m) => m.productId) } },
      select: { name: true },
      take: 10,
    });
    throw new BusinessException(
      ErrorCode.INVENTORY_STALE_COUNT,
      'Un autre inventaire a déjà corrigé ces produits depuis ce comptage : ' +
        `${names.map((p) => `« ${p.name} »`).join(', ')}. ` +
        'Le même écart serait appliqué deux fois — relancez un comptage.',
      HttpStatus.CONFLICT,
    );
  }

  /// Renvoi du même lancement (réponse perdue, double clic) : on rend
  /// l'inventaire déjà ouvert au lieu de refiger un second théorique.
  private async replay(
    dto: CreateInventoryDto,
    user: AuthenticatedUser,
  ): Promise<InventoryDto | null> {
    const existing = await this.prisma.inventory.findUnique({
      where: { clientMutationId: dto.clientMutationId },
      include: INVENTORY_INCLUDE,
    });
    if (!existing) return null;
    assertSameMutation(
      { userId: existing.createdById },
      user.id,
      existing.locationId === dto.locationId && existing.type === dto.type,
      {
        code: ErrorCode.CONFLICT,
        message: `Inventaire déjà lancé (${existing.number}) avec un autre périmètre`,
      },
    );
    return InventoryService.toDto(existing);
  }

  /// COMPLET fige tout ce que le lieu porte ; TOURNANT fige la liste annoncée.
  private static assertScope(dto: CreateInventoryDto): void {
    const tournant = dto.type === InventoryTypeDto.TOURNANT;
    if (tournant && !dto.productIds?.length) {
      throw new BusinessException(
        ErrorCode.VALIDATION_FAILED,
        'productIds : un inventaire tournant compte une liste de produits',
        HttpStatus.UNPROCESSABLE_ENTITY,
      );
    }
    if (!tournant && dto.productIds?.length) {
      throw new BusinessException(
        ErrorCode.VALIDATION_FAILED,
        'productIds : un inventaire complet compte tout le lieu',
        HttpStatus.UNPROCESSABLE_ENTITY,
      );
    }
  }

  /// Lignes figées au lancement : le théorique sert de feuille de comptage.
  /// Un produit sans projection à ce lieu compte pour 0 — c'est justement là
  /// qu'on découvre du stock qu'on croyait absent.
  private static async buildLines(tx: Db, dto: CreateInventoryDto) {
    const tournant = dto.type === InventoryTypeDto.TOURNANT;
    const products = tournant
      ? await tx.product.findMany({
          where: { id: { in: dto.productIds } },
          select: { id: true },
        })
      : await tx.product.findMany({
          where: { stocks: { some: { locationId: dto.locationId } } },
          select: { id: true },
        });
    if (tournant && products.length !== new Set(dto.productIds).size) {
      throw new BusinessException(
        ErrorCode.VALIDATION_FAILED,
        'productIds : produit introuvable',
        HttpStatus.UNPROCESSABLE_ENTITY,
      );
    }

    const stocks = await tx.stock.findMany({
      where: {
        locationId: dto.locationId,
        productId: { in: products.map((p) => p.id) },
      },
      select: { productId: true, quantity: true },
    });
    return products.map((product) => ({
      productId: product.id,
      theoreticalQuantity:
        stocks.find((s) => s.productId === product.id)?.quantity ??
        new Prisma.Decimal(0),
    }));
  }

  private static async currentStock(
    tx: Db,
    productId: string,
    locationId: string,
  ): Promise<Prisma.Decimal> {
    const stock = await tx.stock.findUnique({
      where: { productId_locationId: { productId, locationId } },
      select: { quantity: true },
    });
    return stock?.quantity ?? new Prisma.Decimal(0);
  }

  private static statusFilter(status?: string): Prisma.InventoryWhereInput {
    if (!status) return {};
    // `in` traverse la chaîne de prototypes : liste blanche sur les VALEURS.
    if (!Object.values(InventoryStatus).includes(status as InventoryStatus)) {
      throw new BusinessException(
        ErrorCode.VALIDATION_FAILED,
        `status : statut inconnu — attendus ${Object.values(InventoryStatus).join(', ')}`,
      );
    }
    return { status: status as InventoryStatus };
  }

  private static notFound(): BusinessException {
    return new BusinessException(
      ErrorCode.NOT_FOUND,
      'Inventaire introuvable',
      HttpStatus.NOT_FOUND,
    );
  }

  private static snapshot(
    inventory: InventoryWithLines,
  ): Prisma.InputJsonValue {
    return {
      number: inventory.number,
      status: inventory.status,
      type: inventory.type,
      locationId: inventory.locationId,
      zone: inventory.zone,
      createdById: inventory.createdById,
      validatedById: inventory.validatedById,
      lines: inventory.lines.map((line) => ({
        productId: line.productId,
        theoreticalQuantity: formatQuantity(line.theoreticalQuantity),
        countedQuantity:
          line.countedQuantity === null
            ? null
            : formatQuantity(line.countedQuantity),
        difference: formatQuantity(line.difference),
        state: line.state,
      })),
    };
  }

  private static toDto(inventory: InventoryWithLines): InventoryDto {
    return {
      id: inventory.id,
      number: inventory.number,
      status: inventory.status,
      type: inventory.type as InventoryTypeDto,
      locationId: inventory.locationId,
      zone: inventory.zone,
      createdById: inventory.createdById,
      validatedById: inventory.validatedById,
      startedAt: inventory.startedAt,
      completedAt: inventory.completedAt,
      validatedAt: inventory.validatedAt,
      note: inventory.note,
      updatedAt: inventory.updatedAt,
      lines: inventory.lines.map((line) => ({
        id: line.id,
        productId: line.productId,
        theoreticalQuantity: formatQuantity(line.theoreticalQuantity),
        countedQuantity:
          line.countedQuantity === null
            ? null
            : formatQuantity(line.countedQuantity),
        difference: formatQuantity(line.difference),
        state: line.state,
        note: line.note,
      })),
    };
  }
}
