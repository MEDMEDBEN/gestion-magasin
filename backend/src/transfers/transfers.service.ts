import { HttpStatus, Injectable } from '@nestjs/common';
import { ActorContext, writeAudit } from '../audit/audit-writer';
import { AuthenticatedUser } from '../common/auth.decorators';
import { BusinessException } from '../common/business.exception';
import { nextDocumentNumber } from '../common/document-number';
import { parseSort } from '../common/dto/pagination.dto';
import { ErrorCode } from '../common/error-codes';
import { assertSameMutation, runOnce } from '../common/idempotency';
import { formatQuantity, parseQuantity } from '../common/quantity';
import { Prisma, Transfer, TransferLine } from '../generated/prisma/client';
import { TransferStatus } from '../generated/prisma/enums';
import {
  NOTIFY_DEPOT,
  NOTIFY_MAGASIN,
  NotificationsService,
} from '../notifications/notifications.service';
import { PrismaService } from '../prisma/prisma.service';
import { StockLedgerService } from '../stock/stock-ledger.service';
import {
  CloseTransferDto,
  CreateTransferDto,
  PrepareTransferDto,
  PriorityDto,
  ReceiveTransferDto,
  TransferDto,
  TransferListDto,
  TransferListQueryDto,
} from './dto/transfer.dto';

type Db = Prisma.TransactionClient;
type TransferWithLines = Transfer & { lines: TransferLine[] };

const TRANSFER_INCLUDE = { lines: { orderBy: { id: 'asc' } } } as const;

/// Tris autorisés (liste blanche, CONVENTIONS.md).
const TRANSFER_SORT_FIELDS = ['requestedAt', 'number'] as const;

/// Statuts où la demande vit encore : tout ce qui n'est ni reçu ni abandonné.
const OPEN_STATUSES: TransferStatus[] = [
  'DEMANDEE',
  'ACCEPTEE',
  'EN_PREPARATION',
  'PREPAREE',
  'EN_TRANSIT',
];

/// Statuts où le dépôt peut encore travailler la demande. Rien n'a bougé en
/// stock avant l'expédition : ces états s'abandonnent sans contre-écriture.
const PREPARABLE: TransferStatus[] = [
  'DEMANDEE',
  'ACCEPTEE',
  'EN_PREPARATION',
  'PREPAREE',
];

/// Transferts dépôt → magasin (P0 #8, spec §16 et §17).
///
/// La demande du magasin est un transfert SUIVI, pas un message. Le stock ne
/// bouge qu'à deux moments, et toujours par le journal (règle 2) :
/// - expédition : DÉPÔT − préparé, TRANSIT + préparé ;
/// - réception  : TRANSIT − expédié, MAGASIN + reçu, et le manquant RETOURNE au
///   dépôt pour y être constaté (perte/casse) — rien ne reste coincé en transit.
///
/// Le produit n'est donc vendable au magasin qu'APRÈS réception (spec §17).
/// Chaque transition prend le même verrou de ligne (`lockTransfer`) : une
/// expédition et une annulation simultanées ne peuvent pas passer toutes les deux.
@Injectable()
export class TransfersService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly ledger: StockLedgerService,
  ) {}

  async request(
    dto: CreateTransferDto,
    user: AuthenticatedUser,
    actor: ActorContext,
  ): Promise<TransferDto> {
    return runOnce(
      () => this.replay(this.prisma, dto, user),
      () =>
        this.prisma.$transaction((tx) =>
          this.requestInTx(tx, dto, user, actor),
        ),
    );
  }

  /// Cœur de la demande, dans la transaction de l'appelant (route en ligne ou
  /// synchronisation). `actor` null : la synchronisation écrit l'audit.
  async requestInTx(
    tx: Db,
    dto: CreateTransferDto,
    user: AuthenticatedUser,
    actor: ActorContext | null,
  ): Promise<TransferDto> {
    const from = await TransfersService.resolveLocation(
      tx,
      'DEPOT',
      dto.fromLocationId,
      'fromLocationId',
    );
    const to = await TransfersService.resolveLocation(
      tx,
      'MAGASIN',
      dto.toLocationId,
      'toLocationId',
    );
    const lines = await TransfersService.buildLines(tx, dto);
    const number = await nextDocumentNumber(tx, 'TRANSFERT', 'TRF', 5);
    const transfer = await tx.transfer.create({
      include: TRANSFER_INCLUDE,
      data: {
        id: dto.id,
        number,
        clientMutationId: dto.clientMutationId,
        fromLocationId: from,
        toLocationId: to,
        requestedById: user.id,
        priority: dto.priority ?? 'NORMALE',
        comment: dto.comment ?? null,
        lines: { create: lines },
      },
    });
    if (actor) {
      await writeAudit(tx, actor, {
        action: 'CREATE',
        entityType: 'Transfer',
        entityId: transfer.id,
        newValue: TransfersService.snapshot(transfer),
      });
    }
    // Le dépôt apprend la demande dans la MÊME transaction : pas de demande
    // sans alerte, pas d'alerte sans demande (spec §18).
    await NotificationsService.notifyRoles(
      tx,
      NOTIFY_DEPOT,
      {
        type: 'NOUVELLE_DEMANDE_DEPOT',
        title: `Demande ${transfer.number} à préparer`,
        body: `${transfer.lines.length} produit(s) demandé(s) par le magasin.`,
        priority: transfer.priority,
        operationType: 'TRANSFER',
        operationId: transfer.id,
      },
      user.id,
    );
    return TransfersService.toDto(transfer);
  }

  /// « Je m'en occupe » : le dépôt prend la demande sans encore rien préparer.
  /// Renvoyé sur une demande déjà acceptée, il rend l'état atteint.
  async accept(
    id: string,
    user: AuthenticatedUser,
    actor: ActorContext | null,
    /// Transaction de la synchronisation ; absente = la sienne.
    db?: Db,
  ): Promise<TransferDto> {
    return this.transition(
      id,
      actor,
      (before) => {
        if (before.status === 'ACCEPTEE') return null;
        TransfersService.assertStatus(before, ['DEMANDEE']);
        return {
          data: {
            status: 'ACCEPTEE',
            acceptedAt: new Date(),
            preparedById: user.id,
          },
        };
      },
      'UPDATE',
      db,
    );
  }

  /// Préparation, partielle autorisée (spec §17 : portée par les quantités).
  /// `done: false` sauvegarde un comptage en cours (EN_PREPARATION, reprise
  /// possible) ; `done: true` déclare la préparation finie (PREPAREE).
  async prepare(
    id: string,
    dto: PrepareTransferDto,
    user: AuthenticatedUser,
    actor: ActorContext | null,
    /// Transaction de la synchronisation ; absente = la sienne.
    db?: Db,
  ): Promise<TransferDto> {
    return this.transition(
      id,
      actor,
      (before) => {
        TransfersService.assertStatus(before, PREPARABLE);
        const asked = new Map<string, string>();
        for (const line of dto.lines) {
          if (asked.has(line.productId)) {
            throw new BusinessException(
              ErrorCode.VALIDATION_FAILED,
              'lines.productId : produit répété dans la préparation',
              HttpStatus.UNPROCESSABLE_ENTITY,
            );
          }
          asked.set(line.productId, line.preparedQuantity);
        }
        const lines = before.lines.map((line) => {
          const raw = asked.get(line.productId);
          // Ligne non citée : sa préparation précédente est conservée.
          if (raw === undefined)
            return { id: line.id, quantity: line.preparedQuantity };
          const quantity = parseQuantity(raw, 'lines.preparedQuantity');
          if (quantity.greaterThan(line.requestedQuantity)) {
            throw new BusinessException(
              ErrorCode.VALIDATION_FAILED,
              `Préparation supérieure à la demande : demandé ` +
                `${formatQuantity(line.requestedQuantity)}, préparé ` +
                `${formatQuantity(quantity)} — faites d’abord modifier la demande`,
              HttpStatus.UNPROCESSABLE_ENTITY,
            );
          }
          asked.delete(line.productId);
          return { id: line.id, quantity };
        });
        if (asked.size > 0) {
          throw new BusinessException(
            ErrorCode.VALIDATION_FAILED,
            'lines.productId : produit absent de cette demande',
            HttpStatus.UNPROCESSABLE_ENTITY,
          );
        }
        const done = dto.done ?? true;
        return {
          data: {
            status: done ? 'PREPAREE' : 'EN_PREPARATION',
            acceptedAt: before.acceptedAt ?? new Date(),
            preparedAt: done ? new Date() : null,
            preparedById: user.id,
            lines: {
              update: lines.map((l) => ({
                where: { id: l.id },
                data: { preparedQuantity: l.quantity },
              })),
            },
          },
        };
      },
      'UPDATE',
      db,
    );
  }

  /// Expédition : le stock QUITTE le dépôt pour le transit. À partir d'ici le
  /// transfert ne s'annule plus — la marchandise est partie, elle doit arriver
  /// (règle 7 : on corrige par une opération, jamais en effaçant).
  async ship(
    id: string,
    user: AuthenticatedUser,
    actor: ActorContext | null,
    /// Transaction de la synchronisation ; absente = la sienne.
    db?: Db,
  ): Promise<TransferDto> {
    return this.transition(
      id,
      actor,
      async (before, tx) => {
        TransfersService.assertStatus(before, ['PREPAREE']);
        const shipped = before.lines.filter((l) =>
          l.preparedQuantity.greaterThan(0),
        );
        if (shipped.length === 0) {
          throw new BusinessException(
            ErrorCode.INVALID_STATE_TRANSITION,
            'Rien de préparé : refusez la demande au lieu de l’expédier à vide',
            HttpStatus.CONFLICT,
          );
        }
        const transitId = await TransfersService.transitId(tx);
        // Ordre fixe par produit : deux transferts concurrents ne s'interbloquent pas.
        for (const line of TransfersService.byProduct(shipped)) {
          await this.ledger.applyMovement(tx, {
            productId: line.productId,
            locationId: before.fromLocationId,
            quantity: line.preparedQuantity.negated(),
            sourceLocationId: before.fromLocationId,
            destinationLocationId: transitId,
            type: 'TRANSFERT_SORTIE',
            operationType: 'TRANSFER',
            operationId: before.id,
            userId: user.id,
            comment: before.number,
          });
          await this.ledger.applyMovement(tx, {
            productId: line.productId,
            locationId: transitId,
            quantity: line.preparedQuantity,
            sourceLocationId: before.fromLocationId,
            destinationLocationId: transitId,
            type: 'TRANSFERT_ENTREE',
            operationType: 'TRANSFER',
            operationId: before.id,
            userId: user.id,
            comment: before.number,
          });
        }
        return {
          data: {
            status: 'EN_TRANSIT',
            shippedAt: new Date(),
            preparedById: user.id,
            lines: {
              update: shipped.map((l) => ({
                where: { id: l.id },
                data: { shippedQuantity: l.preparedQuantity },
              })),
            },
          },
        };
      },
      'UPDATE',
      db,
    );
  }

  /// Réception au magasin : le transit se vide, le magasin reçoit ce qui est
  /// réellement arrivé, et l'ÉCART retourne au dépôt avec sa mention. C'est là
  /// qu'il se constate (déclaration de perte/casse) : le transit, lui, ne porte
  /// aucune projection déclarable et ne doit jamais rester chargé.
  async receive(
    id: string,
    dto: ReceiveTransferDto,
    user: AuthenticatedUser,
    actor: ActorContext | null,
    /// Transaction de la synchronisation ; absente = la sienne.
    db?: Db,
  ): Promise<TransferDto> {
    return this.transition(
      id,
      actor,
      async (before, tx) => {
        TransfersService.assertStatus(before, ['EN_TRANSIT']);
        const asked = new Map<string, string>();
        for (const line of dto.lines ?? []) {
          if (asked.has(line.productId)) {
            throw new BusinessException(
              ErrorCode.VALIDATION_FAILED,
              'lines.productId : produit répété dans la réception',
              HttpStatus.UNPROCESSABLE_ENTITY,
            );
          }
          asked.set(line.productId, line.receivedQuantity);
        }
        const received = before.lines
          .filter((l) => l.shippedQuantity.greaterThan(0))
          .map((line) => {
            const raw = asked.get(line.productId);
            // Ligne non citée : tout ce qui est parti est arrivé.
            const quantity =
              raw === undefined
                ? line.shippedQuantity
                : parseQuantity(raw, 'lines.receivedQuantity');
            if (quantity.greaterThan(line.shippedQuantity)) {
              throw new BusinessException(
                ErrorCode.VALIDATION_FAILED,
                `Réception supérieure à l’expédition : expédié ` +
                  `${formatQuantity(line.shippedQuantity)}, reçu ` +
                  `${formatQuantity(quantity)}`,
                HttpStatus.UNPROCESSABLE_ENTITY,
              );
            }
            asked.delete(line.productId);
            return { line, quantity };
          });
        if (asked.size > 0) {
          throw new BusinessException(
            ErrorCode.VALIDATION_FAILED,
            'lines.productId : produit absent des lignes expédiées',
            HttpStatus.UNPROCESSABLE_ENTITY,
          );
        }

        const transitId = await TransfersService.transitId(tx);
        for (const { line, quantity } of TransfersService.byProduct(
          received,
          (r) => r.line.productId,
        )) {
          await this.ledger.applyMovement(tx, {
            productId: line.productId,
            locationId: transitId,
            quantity: line.shippedQuantity.negated(),
            sourceLocationId: transitId,
            destinationLocationId: before.toLocationId,
            type: 'TRANSFERT_SORTIE',
            operationType: 'TRANSFER',
            operationId: before.id,
            userId: user.id,
            comment: before.number,
          });
          if (quantity.greaterThan(0)) {
            await this.ledger.applyMovement(tx, {
              productId: line.productId,
              locationId: before.toLocationId,
              quantity,
              sourceLocationId: transitId,
              destinationLocationId: before.toLocationId,
              type: 'TRANSFERT_ENTREE',
              operationType: 'TRANSFER',
              operationId: before.id,
              userId: user.id,
              comment: before.number,
            });
          }
          const missing = line.shippedQuantity.sub(quantity);
          if (missing.greaterThan(0)) {
            await this.ledger.applyMovement(tx, {
              productId: line.productId,
              locationId: before.fromLocationId,
              quantity: missing,
              sourceLocationId: transitId,
              destinationLocationId: before.fromLocationId,
              type: 'TRANSFERT_ENTREE',
              operationType: 'TRANSFER',
              operationId: before.id,
              userId: user.id,
              comment: `${before.number} — écart de transfert, non arrivé au magasin`,
            });
          }
        }
        return {
          data: {
            status: 'RECUE',
            receivedAt: new Date(),
            receivedById: user.id,
            lines: {
              update: received.map(({ line, quantity }) => ({
                where: { id: line.id },
                data: { receivedQuantity: quantity },
              })),
            },
          },
        };
      },
      'UPDATE',
      db,
    );
  }

  /// Refus (le dépôt ne suivra pas) ou annulation (le demandeur renonce).
  /// Rien n'a bougé en stock avant l'expédition : il n'y a rien à contre-passer,
  /// et après l'expédition c'est refusé (la marchandise est en route).
  async close(
    id: string,
    dto: CloseTransferDto,
    user: AuthenticatedUser,
    actor: ActorContext | null,
    /// Transaction de la synchronisation ; absente = la sienne.
    db?: Db,
  ): Promise<TransferDto> {
    return this.transition(
      id,
      actor,
      (before) => {
        TransfersService.assertStatus(before, PREPARABLE);
        TransfersService.assertCanClose(before, dto, user);
        return {
          data:
            dto.status === 'REFUSEE'
              ? { status: 'REFUSEE', refusedAt: new Date() }
              : { status: 'ANNULEE', cancelledAt: new Date() },
        };
      },
      'CANCEL',
      db,
    );
  }

  async findAll(
    query: TransferListQueryDto,
    user: AuthenticatedUser,
  ): Promise<TransferListDto> {
    const where: Prisma.TransferWhereInput = {
      ...TransfersService.statusFilter(query.status),
      ...(query.mine && { requestedById: user.id }),
    };
    const [rows, total] = await Promise.all([
      this.prisma.transfer.findMany({
        where,
        include: TRANSFER_INCLUDE,
        skip: (query.page - 1) * query.limit,
        take: query.limit,
        orderBy: [
          parseSort(query.sort, TRANSFER_SORT_FIELDS, { requestedAt: 'desc' }),
          { id: 'desc' },
        ],
      }),
      this.prisma.transfer.count({ where }),
    ]);
    return {
      data: rows.map(TransfersService.toDto),
      meta: { page: query.page, limit: query.limit, total },
    };
  }

  async findOne(id: string): Promise<TransferDto> {
    const transfer = await this.prisma.transfer.findUnique({
      where: { id },
      include: TRANSFER_INCLUDE,
    });
    if (!transfer) throw TransfersService.notFound();
    return TransfersService.toDto(transfer);
  }

  /// Toute transition passe ICI : verrou de ligne pris AVANT la lecture, mise à
  /// jour et audit dans la MÊME transaction. `build` rend `null` quand l'état
  /// visé est déjà atteint (renvoi d'une action) : rien n'est réécrit.
  private async transition(
    id: string,
    actor: ActorContext | null,
    build: (
      before: TransferWithLines,
      tx: Db,
    ) =>
      | Promise<{ data: Prisma.TransferUpdateInput } | null>
      | ({ data: Prisma.TransferUpdateInput } | null),
    action: 'UPDATE' | 'CANCEL' = 'UPDATE',
    db?: Db,
  ): Promise<TransferDto> {
    const run = async (tx: Db): Promise<TransferDto> => {
      const before = await TransfersService.lockTransfer(tx, id);
      const change = await build(before, tx);
      if (!change) return TransfersService.toDto(before);
      const after = await tx.transfer.update({
        where: { id },
        include: TRANSFER_INCLUDE,
        data: change.data,
      });
      // `actor` null : la synchronisation écrit elle-même l'audit.
      if (actor) {
        await writeAudit(tx, actor, {
          action,
          entityType: 'Transfer',
          entityId: id,
          oldValue: TransfersService.snapshot(before),
          newValue: TransfersService.snapshot(after),
        });
      }
      await TransfersService.notifyTransition(tx, before, after);
      return TransfersService.toDto(after);
    };
    return db ? run(db) : this.prisma.$transaction(run);
  }

  /// Qui doit savoir, à chaque étape franchie (spec §18). UN seul endroit :
  /// une transition ajoutée plus tard hérite du même traitement, et personne
  /// n'est prévenu de ce qu'il vient lui-même de faire.
  ///
  /// L'auteur est lu sur le TRANSFERT (`preparedById`, `receivedById`) et non
  /// sur l'`actor` : hors-ligne, la synchronisation n'a pas d'acteur HTTP.
  private static async notifyTransition(
    tx: Db,
    before: TransferWithLines,
    after: Transfer,
  ): Promise<void> {
    if (before.status === after.status) return;
    const link = {
      operationType: 'TRANSFER' as const,
      operationId: after.id,
      priority: after.priority,
    };
    switch (after.status) {
      // Prête : le magasin peut venir la chercher. Adressée au MAGASIN entier
      // et pas au seul demandeur — s'il est absent ou désactivé, la
      // marchandise resterait prête sans que personne ne le sache.
      case 'PREPAREE':
        await NotificationsService.notifyRoles(
          tx,
          NOTIFY_MAGASIN,
          {
            ...link,
            type: 'DEMANDE_PRETE',
            title: `Demande ${after.number} prête au dépôt`,
          },
          after.preparedById ?? undefined,
        );
        break;
      // Partie : le magasin doit la réceptionner à l'arrivée.
      case 'EN_TRANSIT':
        await NotificationsService.notifyRoles(
          tx,
          NOTIFY_MAGASIN,
          {
            ...link,
            type: 'TRANSFERT',
            title: `Transfert ${after.number} en route vers le magasin`,
          },
          after.preparedById ?? undefined,
        );
        break;
      // Reçue : le dépôt sait que sa marchandise est arrivée (et qu'un écart
      // éventuel lui est revenu).
      case 'RECUE':
        await NotificationsService.notifyRoles(
          tx,
          NOTIFY_DEPOT,
          {
            ...link,
            type: 'TRANSFERT_RECU',
            title: `Transfert ${after.number} reçu au magasin`,
          },
          after.receivedById ?? undefined,
        );
        break;
      // Refusée : seul le demandeur attend cette réponse.
      case 'REFUSEE':
        await NotificationsService.notifyUsers(tx, [after.requestedById], {
          ...link,
          type: 'TRANSFERT',
          title: `Demande ${after.number} refusée par le dépôt`,
          priority: 'HAUTE',
        });
        break;
      // Annulée par le magasin : le dépôt est peut-être EN TRAIN de la
      // préparer. C'est le travail pour rien que cette feature doit éviter.
      case 'ANNULEE':
        await NotificationsService.notifyRoles(
          tx,
          NOTIFY_DEPOT,
          {
            ...link,
            type: 'TRANSFERT',
            title: `Demande ${after.number} annulée`,
            priority: 'HAUTE',
          },
          after.requestedById,
        );
        break;
      default:
        break;
    }
  }

  /// Qui peut clore (matrice de docs/permissions.md) : le DÉPÔT refuse, le
  /// DEMANDEUR annule. Partagé avec la synchronisation, qui le vérifie AVANT de
  /// reconnaître une clôture déjà faite.
  static assertCanClose(
    before: TransferWithLines,
    dto: CloseTransferDto,
    user: AuthenticatedUser,
  ): void {
    if (dto.status === 'REFUSEE') {
      if (!TransfersService.hasRole(user, 'ADMIN', 'MAGASINIER')) {
        throw new BusinessException(
          ErrorCode.FORBIDDEN_ROLE,
          'Seul le dépôt (magasinier) ou un administrateur refuse une demande',
          HttpStatus.FORBIDDEN,
        );
      }
    } else if (
      !user.roles.includes('ADMIN') &&
      before.requestedById !== user.id
    ) {
      throw new BusinessException(
        ErrorCode.FORBIDDEN_ROLE,
        'Seul l’auteur de la demande ou un administrateur l’annule',
        HttpStatus.FORBIDDEN,
      );
    }
  }

  /// Point d'entrée UNIQUE de toute écriture sur un transfert (même rôle que
  /// `PurchaseOrdersService.lockOrder`) : le `FOR UPDATE` sérialise expédition,
  /// réception, refus et annulation simultanés.
  static async lockTransfer(tx: Db, id: string): Promise<TransferWithLines> {
    await tx.$queryRaw`SELECT "id" FROM "Transfer" WHERE "id" = ${id}::uuid FOR UPDATE`;
    const transfer = await tx.transfer.findUnique({
      where: { id },
      include: TRANSFER_INCLUDE,
    });
    if (!transfer) throw TransfersService.notFound();
    return transfer;
  }

  /// Renvoi de la même demande (réponse perdue, double clic) : on rend celle
  /// déjà enregistrée au lieu d'en créer une seconde.
  async replay(
    db: Db,
    dto: CreateTransferDto,
    user: AuthenticatedUser,
  ): Promise<TransferDto | null> {
    const existing = await db.transfer.findUnique({
      where: { clientMutationId: dto.clientMutationId },
      include: TRANSFER_INCLUDE,
    });
    if (!existing) return null;
    assertSameMutation(
      { userId: existing.requestedById },
      user.id,
      TransfersService.contentKey(existing) === TransfersService.dtoKey(dto),
      {
        code: ErrorCode.CONFLICT,
        message: `Demande déjà enregistrée (${existing.number}) avec un autre contenu`,
      },
    );
    return TransfersService.toDto(existing);
  }

  /// Lignes de la demande : produit ACTIF, quantité > 0, un seul produit par
  /// ligne (la préparation et la réception se désignent par produit).
  private static async buildLines(tx: Db, dto: CreateTransferDto) {
    const products = await tx.product.findMany({
      where: { id: { in: dto.lines.map((l) => l.productId) }, isActive: true },
      select: { id: true },
    });
    const seen = new Set<string>();
    return dto.lines.map((line) => {
      if (!products.some((p) => p.id === line.productId)) {
        throw new BusinessException(
          ErrorCode.VALIDATION_FAILED,
          'lines.productId : produit introuvable ou désactivé',
          HttpStatus.UNPROCESSABLE_ENTITY,
        );
      }
      if (seen.has(line.productId)) {
        throw new BusinessException(
          ErrorCode.VALIDATION_FAILED,
          'lines.productId : un produit ne peut figurer qu’une fois par demande',
          HttpStatus.UNPROCESSABLE_ENTITY,
        );
      }
      seen.add(line.productId);
      const quantity = parseQuantity(line.quantity, 'lines.quantity');
      if (quantity.lessThanOrEqualTo(0)) {
        throw new BusinessException(
          ErrorCode.VALIDATION_FAILED,
          'lines.quantity : quantité strictement positive attendue',
          HttpStatus.UNPROCESSABLE_ENTITY,
        );
      }
      return { productId: line.productId, requestedQuantity: quantity };
    });
  }

  /// Emplacement de l'espèce attendue. Le périmètre est 1 magasin + 1 dépôt :
  /// sans précision le serveur le résout lui-même, et un identifiant fourni doit
  /// désigner cette espèce (un transfert n'inverse pas le sens du flux).
  private static async resolveLocation(
    tx: Db,
    type: 'DEPOT' | 'MAGASIN',
    id: string | undefined,
    field: string,
  ): Promise<string> {
    const location = await tx.location.findFirst({
      where: { type, isActive: true, ...(id && { id }) },
      select: { id: true },
    });
    if (!location) {
      throw new BusinessException(
        ErrorCode.VALIDATION_FAILED,
        `${field} : ${type === 'DEPOT' ? 'dépôt' : 'magasin'} actif attendu`,
        HttpStatus.UNPROCESSABLE_ENTITY,
      );
    }
    return location.id;
  }

  private static async transitId(tx: Db): Promise<string> {
    const transit = await tx.location.findFirst({
      where: { type: 'TRANSIT', isActive: true },
      select: { id: true },
    });
    if (!transit) {
      throw new BusinessException(
        ErrorCode.CONFLICT,
        'Aucun emplacement de transit actif : impossible de déplacer la marchandise',
        HttpStatus.CONFLICT,
      );
    }
    return transit.id;
  }

  private static statusFilter(status?: string): Prisma.TransferWhereInput {
    if (!status) return {};
    if (status === 'EN_COURS') return { status: { in: OPEN_STATUSES } };
    // `in` traverse la chaîne de prototypes : `constructor`, `toString`… la
    // passeraient et atteindraient Prisma comme valeur d'énum (500). Liste
    // blanche RÉELLE sur les valeurs.
    if (!Object.values(TransferStatus).includes(status as TransferStatus)) {
      throw new BusinessException(
        ErrorCode.VALIDATION_FAILED,
        `status : statut inconnu — attendus ${Object.keys(TransferStatus).join(', ')} ou EN_COURS`,
      );
    }
    return { status: status as TransferStatus };
  }

  private static assertStatus(
    transfer: TransferWithLines,
    allowed: readonly TransferStatus[],
  ): void {
    if (!allowed.includes(transfer.status)) {
      throw new BusinessException(
        ErrorCode.INVALID_STATE_TRANSITION,
        `Transfert ${transfer.status.toLowerCase().replace(/_/g, ' ')} : cette action n’est plus possible`,
        HttpStatus.CONFLICT,
      );
    }
  }

  private static hasRole(user: AuthenticatedUser, ...roles: string[]): boolean {
    return roles.some((role) => user.roles.includes(role));
  }

  /// Verrouillage de stock dans un ordre stable, par produit.
  private static byProduct<T>(
    items: T[],
    key: (item: T) => string = (item) =>
      (item as { productId: string }).productId,
  ): T[] {
    return [...items].sort((a, b) => key(a).localeCompare(key(b)));
  }

  private static notFound(): BusinessException {
    return new BusinessException(
      ErrorCode.NOT_FOUND,
      'Transfert introuvable',
      HttpStatus.NOT_FOUND,
    );
  }

  /// Empreinte du CONTENU : deux envois de même empreinte sont la même demande.
  /// Les emplacements n'y figurent PAS : le client peut les omettre (le serveur
  /// les résout), et les comparer ferait passer un renvoi identique pour un
  /// contenu différent.
  private static key(input: {
    priority: string;
    comment: string | null;
    lines: { productId: string; quantity: string }[];
  }): string {
    return [
      input.priority,
      input.comment ?? '',
      ...input.lines.map((l) => `${l.productId}|${l.quantity}`).sort(),
    ].join(';');
  }

  private static contentKey(transfer: TransferWithLines): string {
    return TransfersService.key({
      priority: transfer.priority,
      comment: transfer.comment,
      lines: transfer.lines.map((l) => ({
        productId: l.productId,
        quantity: formatQuantity(l.requestedQuantity),
      })),
    });
  }

  private static dtoKey(dto: CreateTransferDto): string {
    return TransfersService.key({
      priority: dto.priority ?? PriorityDto.NORMALE,
      comment: dto.comment ?? '',
      lines: dto.lines.map((l) => ({
        productId: l.productId,
        quantity: formatQuantity(parseQuantity(l.quantity, 'lines.quantity')),
      })),
    });
  }

  /// Trace d'audit : l'état métier du transfert, sans rien d'inutile.
  private static snapshot(transfer: TransferWithLines): Prisma.InputJsonValue {
    return {
      number: transfer.number,
      status: transfer.status,
      priority: transfer.priority,
      fromLocationId: transfer.fromLocationId,
      toLocationId: transfer.toLocationId,
      requestedById: transfer.requestedById,
      preparedById: transfer.preparedById,
      receivedById: transfer.receivedById,
      lines: transfer.lines.map((l) => ({
        productId: l.productId,
        requestedQuantity: formatQuantity(l.requestedQuantity),
        preparedQuantity: formatQuantity(l.preparedQuantity),
        shippedQuantity: formatQuantity(l.shippedQuantity),
        receivedQuantity: formatQuantity(l.receivedQuantity),
      })),
    };
  }

  static toDto(transfer: TransferWithLines): TransferDto {
    return {
      id: transfer.id,
      number: transfer.number,
      status: transfer.status,
      priority: transfer.priority as PriorityDto,
      fromLocationId: transfer.fromLocationId,
      toLocationId: transfer.toLocationId,
      requestedById: transfer.requestedById,
      preparedById: transfer.preparedById,
      receivedById: transfer.receivedById,
      requestedAt: transfer.requestedAt,
      preparedAt: transfer.preparedAt,
      shippedAt: transfer.shippedAt,
      receivedAt: transfer.receivedAt,
      comment: transfer.comment,
      updatedAt: transfer.updatedAt,
      lines: transfer.lines.map((line) => ({
        id: line.id,
        productId: line.productId,
        requestedQuantity: formatQuantity(line.requestedQuantity),
        preparedQuantity: formatQuantity(line.preparedQuantity),
        shippedQuantity: formatQuantity(line.shippedQuantity),
        receivedQuantity: formatQuantity(line.receivedQuantity),
      })),
    };
  }
}
