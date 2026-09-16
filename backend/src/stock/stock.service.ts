import { HttpStatus, Injectable } from '@nestjs/common';
import { ActorContext, writeAudit } from '../audit/audit-writer';
import { AuthenticatedUser } from '../common/auth.decorators';
import { BusinessException } from '../common/business.exception';
import { parseSort } from '../common/dto/pagination.dto';
import { parseApiDate } from '../common/api-date';
import { ErrorCode } from '../common/error-codes';
import { PERMISSIONS } from '../common/permissions';
import { formatQuantity, parseQuantity } from '../common/quantity';
import {
  Prisma,
  Stock,
  StockLossDeclaration,
  StockMovement,
} from '../generated/prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import {
  DeclareLossDto,
  LossQueryDto,
  MovementQueryDto,
  RejectLossDto,
  StockListDto,
  StockLossDto,
  StockLossListDto,
  StockLossStatusDto,
  StockMovementDto,
  StockMovementListDto,
  StockMovementTypeDto,
  StockQueryDto,
} from './dto/stock.dto';
import { StockLedgerService } from './stock-ledger.service';

type Db = Prisma.TransactionClient;
type Viewer = Pick<AuthenticatedUser, 'id' | 'permissions'>;

@Injectable()
export class StockService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly ledger: StockLedgerService,
  ) {}

  /// Stock par produit × emplacement. Le stock du dépôt (tout ce qui n'est pas le
  /// MAGASIN) exige en plus `stock.read.warehouse` (docs/permissions.md).
  async findStock(query: StockQueryDto, viewer: Viewer): Promise<StockListDto> {
    const where: Prisma.StockWhereInput = {
      ...(query.productId && { productId: query.productId }),
      ...(query.locationId && { locationId: query.locationId }),
      ...StockService.visibleLocations(viewer),
    };
    const orderBy = parseSort(query.sort, ['updatedAt'] as const, {
      updatedAt: 'desc',
    });
    const [rows, total] = await Promise.all([
      this.prisma.stock.findMany({
        where,
        skip: (query.page - 1) * query.limit,
        take: query.limit,
        orderBy: [orderBy, { id: 'asc' }],
      }),
      this.prisma.stock.count({ where }),
    ]);
    return {
      data: rows.map(StockService.stockToDto),
      meta: { page: query.page, limit: query.limit, total },
    };
  }

  /// Journal immuable des mouvements, le plus récent d'abord.
  async findMovements(
    query: MovementQueryDto,
    viewer: Viewer,
  ): Promise<StockMovementListDto> {
    const where: Prisma.StockMovementWhereInput = {
      ...(query.productId && { productId: query.productId }),
      ...(query.locationId && { locationId: query.locationId }),
      ...(query.type && { type: query.type }),
      ...((query.from || query.to) && {
        createdAt: {
          ...(query.from && {
            gte: parseApiDate(query.from, 'from'),
          }),
          ...(query.to && { lt: parseApiDate(query.to, 'to') }),
        },
      }),
      ...StockService.visibleLocations(viewer),
    };
    const [rows, total] = await Promise.all([
      this.prisma.stockMovement.findMany({
        where,
        skip: (query.page - 1) * query.limit,
        take: query.limit,
        orderBy: [
          parseSort(query.sort, ['createdAt'] as const, { createdAt: 'desc' }),
          { id: 'desc' },
        ],
      }),
      this.prisma.stockMovement.count({ where }),
    ]);
    // Le détail d'une perte (constat libre, déclarant) relève de `stock.loss` :
    // le vendeur voit le mouvement dans le journal, pas qui l'a déclaré ni pourquoi.
    const seesLossDetail = viewer.permissions.includes(PERMISSIONS.STOCK_LOSS);
    return {
      data: rows.map((row) => {
        const movement = StockService.movementToDto(row);
        return movement.type === StockMovementTypeDto.PERTE_CASSE &&
          !seesLossDetail
          ? { ...movement, comment: null, userId: null, operationId: null }
          : movement;
      }),
      meta: { page: query.page, limit: query.limit, total },
    };
  }

  async findLosses(query: LossQueryDto): Promise<StockLossListDto> {
    const where: Prisma.StockLossDeclarationWhereInput = {
      ...(query.status && { status: query.status }),
    };
    const [rows, total] = await Promise.all([
      this.prisma.stockLossDeclaration.findMany({
        where,
        skip: (query.page - 1) * query.limit,
        take: query.limit,
        orderBy: [
          parseSort(query.sort, ['createdAt'] as const, { createdAt: 'desc' }),
          { id: 'desc' },
        ],
      }),
      this.prisma.stockLossDeclaration.count({ where }),
    ]);
    return {
      data: rows.map(StockService.lossToDto),
      meta: { page: query.page, limit: query.limit, total },
    };
  }

  /// Déclaration en ligne : sa propre transaction, audit compris.
  async declareLoss(
    dto: DeclareLossDto,
    user: AuthenticatedUser,
    actor: ActorContext,
  ): Promise<StockLossDto> {
    // Renvoi du MÊME formulaire (réponse perdue après le commit) : on rend la
    // déclaration existante au lieu d'en créer une seconde — une perte ne doit
    // jamais être retirée deux fois du stock. L'id est généré par le client.
    if (dto.id) {
      const existing = await this.prisma.stockLossDeclaration.findUnique({
        where: { id: dto.id },
      });
      if (existing?.declaredById === user.id) {
        return StockService.lossToDto(existing);
      }
    }
    return this.prisma.$transaction(async (tx) => {
      const loss = await this.declareLossInTx(tx, dto, user);
      // Même action qu'hors-ligne (handler de sync) : la déclaration est CRÉÉE ;
      // son application éventuelle est tracée par le mouvement du journal.
      await writeAudit(tx, actor, {
        action: 'CREATE',
        entityType: 'StockLossDeclaration',
        entityId: loss.id,
        newValue: StockService.lossAudit(loss),
      });
      return loss;
    });
  }

  /// Cœur partagé par la route en ligne ET le handler de sync (même règle des
  /// deux côtés) : un compte qui peut valider (`stock.adjust.validate`, ADMIN)
  /// applique directement ; les autres (MAGASINIER) créent une déclaration EN
  /// ATTENTE — le stock ne bouge qu'à la validation (décision 2026-09-14).
  async declareLossInTx(
    tx: Db,
    dto: DeclareLossDto,
    user: Pick<AuthenticatedUser, 'id' | 'permissions'>,
  ): Promise<StockLossDto> {
    const quantity = parseQuantity(dto.quantity);
    if (quantity.lessThanOrEqualTo(0)) {
      throw new BusinessException(
        ErrorCode.VALIDATION_FAILED,
        'La quantité perdue doit être strictement positive',
        HttpStatus.UNPROCESSABLE_ENTITY,
      );
    }
    const product = await tx.product.findUnique({
      where: { id: dto.productId },
      select: { isActive: true },
    });
    const location = await tx.location.findUnique({
      where: { id: dto.locationId },
      select: { isActive: true, type: true },
    });
    if (!product?.isActive || !location?.isActive) {
      throw new BusinessException(
        ErrorCode.VALIDATION_FAILED,
        'Produit ou emplacement introuvable ou inactif',
        HttpStatus.UNPROCESSABLE_ENTITY,
      );
    }
    // Le stock vit au MAGASIN et au DEPOT : une position (EMPLACEMENT) ou le
    // TRANSIT ne portent pas de projection propre à déclarer en perte.
    if (location.type !== 'MAGASIN' && location.type !== 'DEPOT') {
      throw new BusinessException(
        ErrorCode.VALIDATION_FAILED,
        'Une perte se déclare au magasin ou au dépôt',
        HttpStatus.UNPROCESSABLE_ENTITY,
      );
    }

    const created = await tx.stockLossDeclaration.create({
      data: {
        id: dto.id,
        productId: dto.productId,
        locationId: dto.locationId,
        quantity,
        comment: dto.comment ?? null,
        declaredById: user.id,
      },
    });
    if (!user.permissions.includes(PERMISSIONS.STOCK_ADJUST_VALIDATE)) {
      return StockService.lossToDto(created);
    }
    return this.applyLoss(tx, created, user.id, null);
  }

  async validateLoss(
    id: string,
    user: AuthenticatedUser,
    actor: ActorContext,
  ): Promise<StockLossDto> {
    return this.prisma.$transaction(async (tx) => {
      const pending = await StockService.claimPending(tx, id);
      const loss = await this.applyLoss(tx, pending, user.id, null);
      await writeAudit(tx, actor, {
        action: 'VALIDATE',
        entityType: 'StockLossDeclaration',
        entityId: id,
        oldValue: StockService.lossAudit(StockService.lossToDto(pending)),
        newValue: StockService.lossAudit(loss),
      });
      return loss;
    });
  }

  async rejectLoss(
    id: string,
    dto: RejectLossDto,
    user: AuthenticatedUser,
    actor: ActorContext,
  ): Promise<StockLossDto> {
    return this.prisma.$transaction(async (tx) => {
      const pending = await StockService.claimPending(tx, id);
      const rejected = await tx.stockLossDeclaration.update({
        where: { id },
        data: {
          status: 'REFUSEE',
          decidedById: user.id,
          decidedAt: new Date(),
          decisionNote: dto.note ?? null,
        },
      });
      const loss = StockService.lossToDto(rejected);
      await writeAudit(tx, actor, {
        action: 'CANCEL',
        entityType: 'StockLossDeclaration',
        entityId: id,
        oldValue: StockService.lossAudit(StockService.lossToDto(pending)),
        newValue: StockService.lossAudit(loss),
      });
      return loss;
    });
  }

  /// Verrouille une déclaration EN ATTENTE : deux admins qui valident en même
  /// temps n'appliquent pas deux fois la perte.
  private static async claimPending(
    tx: Db,
    id: string,
  ): Promise<StockLossDeclaration> {
    const [locked] = await tx.$queryRaw<{ id: string }[]>`
      SELECT "id" FROM "StockLossDeclaration" WHERE "id" = ${id}::uuid FOR UPDATE`;
    const loss = locked
      ? await tx.stockLossDeclaration.findUnique({ where: { id } })
      : null;
    if (!loss) {
      throw new BusinessException(
        ErrorCode.NOT_FOUND,
        'Déclaration de perte introuvable',
        HttpStatus.NOT_FOUND,
      );
    }
    if (loss.status !== 'EN_ATTENTE') {
      throw new BusinessException(
        ErrorCode.INVALID_STATE_TRANSITION,
        'Cette déclaration a déjà été traitée',
        HttpStatus.CONFLICT,
      );
    }
    return loss;
  }

  /// Applique la perte : mouvement négatif + projection (anti-stock-négatif par
  /// le journal), puis la déclaration passe VALIDEE — tout dans `tx`.
  private async applyLoss(
    tx: Db,
    loss: StockLossDeclaration,
    deciderId: string,
    note: string | null,
  ): Promise<StockLossDto> {
    const applied = await this.ledger.applyMovement(tx, {
      productId: loss.productId,
      locationId: loss.locationId,
      quantity: loss.quantity.negated(),
      type: StockMovementTypeDto.PERTE_CASSE,
      operationType: 'MANUAL',
      operationId: loss.id,
      userId: loss.declaredById,
      comment: loss.comment,
    });
    const validated = await tx.stockLossDeclaration.update({
      where: { id: loss.id },
      data: {
        status: 'VALIDEE',
        decidedById: deciderId,
        decidedAt: new Date(),
        decisionNote: note,
        movementId: applied.movementId,
      },
    });
    return StockService.lossToDto(validated);
  }

  static visibleLocations(viewer: Pick<Viewer, 'permissions'>) {
    return viewer.permissions.includes(PERMISSIONS.STOCK_READ_WAREHOUSE)
      ? {}
      : { location: { type: 'MAGASIN' as const } };
  }

  static stockToDto(stock: Stock) {
    return {
      productId: stock.productId,
      locationId: stock.locationId,
      quantity: formatQuantity(stock.quantity),
      reservedQuantity: formatQuantity(stock.reservedQuantity),
      inTransitQuantity: formatQuantity(stock.inTransitQuantity),
      availableQuantity: formatQuantity(
        stock.quantity.minus(stock.reservedQuantity),
      ),
      updatedAt: stock.updatedAt,
    };
  }

  static movementToDto(movement: StockMovement): StockMovementDto {
    return {
      id: movement.id,
      productId: movement.productId,
      locationId: movement.locationId,
      quantity: formatQuantity(movement.quantity),
      type: movement.type as StockMovementTypeDto,
      operationType: movement.operationType,
      operationId: movement.operationId,
      userId: movement.userId,
      comment: movement.comment,
      createdAt: movement.createdAt,
    };
  }

  static lossToDto(loss: StockLossDeclaration): StockLossDto {
    return {
      id: loss.id,
      productId: loss.productId,
      locationId: loss.locationId,
      quantity: formatQuantity(loss.quantity),
      comment: loss.comment,
      status: loss.status as StockLossStatusDto,
      declaredById: loss.declaredById,
      decidedById: loss.decidedById,
      decidedAt: loss.decidedAt,
      decisionNote: loss.decisionNote,
      movementId: loss.movementId,
      createdAt: loss.createdAt,
    };
  }

  static lossAudit(loss: StockLossDto): Prisma.InputJsonObject {
    return {
      productId: loss.productId,
      locationId: loss.locationId,
      quantity: loss.quantity,
      status: loss.status,
      comment: loss.comment,
      decisionNote: loss.decisionNote,
      movementId: loss.movementId,
    };
  }
}
