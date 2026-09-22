import { HttpStatus, Injectable } from '@nestjs/common';
import { IsIn } from 'class-validator';
import { RoleCode } from '../../common/auth.decorators';
import { BusinessException } from '../../common/business.exception';
import { ErrorCode } from '../../common/error-codes';
import { PERMISSIONS, PermissionCode } from '../../common/permissions';
import { IsCanonicalUuid } from '../../common/validation';
import { validatePayload } from '../../common/validate-payload';
import {
  AuditAction,
  OperationType,
  TransferStatus,
} from '../../generated/prisma/enums';
import { PrismaService } from '../../prisma/prisma.service';
import {
  CloseTransferDto,
  CreateTransferDto,
  PrepareTransferDto,
  ReceiveTransferDto,
  TransferDto,
} from '../../transfers/dto/transfer.dto';
import { TransfersService } from '../../transfers/transfers.service';
import {
  SyncApplyResult,
  SyncMutationContext,
  SyncMutationHandler,
} from '../sync-mutation.handler';

const ACTIONS = [
  'REQUEST',
  'ACCEPT',
  'PREPARE',
  'SHIP',
  'RECEIVE',
  'CLOSE',
] as const;
type Action = (typeof ACTIONS)[number];

/// Enveloppe d'une étape : quelle action, sur quel transfert, sous quelle clé.
/// Le reste du corps est celui de la route en ligne de l'étape.
class StepEnvelopeDto {
  @IsIn(ACTIONS) action!: Action;
  @IsCanonicalUuid() clientMutationId!: string;
  @IsCanonicalUuid() transferId!: string;
}

type TransferPayload =
  | { action: 'REQUEST'; clientMutationId: string; dto: CreateTransferDto }
  | {
      action: Exclude<Action, 'REQUEST'>;
      clientMutationId: string;
      transferId: string;
      dto: PrepareTransferDto | ReceiveTransferDto | CloseTransferDto | object;
    };

/// Droits de CHAQUE étape — strictement ceux de la route en ligne
/// (`transfers.controller.ts`). Le moteur ne contrôle qu'un plancher commun.
const STEP_RIGHTS: Record<
  Action,
  { roles: RoleCode[]; permission: PermissionCode }
> = {
  REQUEST: {
    roles: [RoleCode.ADMIN, RoleCode.VENDEUR],
    permission: PERMISSIONS.TRANSFER_REQUEST,
  },
  ACCEPT: {
    roles: [RoleCode.ADMIN, RoleCode.MAGASINIER],
    permission: PERMISSIONS.TRANSFER_PREPARE,
  },
  PREPARE: {
    roles: [RoleCode.ADMIN, RoleCode.MAGASINIER],
    permission: PERMISSIONS.TRANSFER_PREPARE,
  },
  SHIP: {
    roles: [RoleCode.ADMIN, RoleCode.MAGASINIER],
    permission: PERMISSIONS.TRANSFER_PREPARE,
  },
  RECEIVE: {
    roles: [RoleCode.ADMIN, RoleCode.VENDEUR],
    permission: PERMISSIONS.TRANSFER_RECEIVE,
  },
  CLOSE: {
    roles: [RoleCode.ADMIN, RoleCode.VENDEUR, RoleCode.MAGASINIER],
    permission: PERMISSIONS.TRANSFER_CANCEL,
  },
};

/// États où l'étape est DÉJÀ faite : la même étape, faite en ligne (réponse
/// perdue) puis revenue par la file, est RECONNUE au lieu d'être refusée
/// comme « transition invalide ». (Même règle que `accept` en ligne.)
const REACHED: Record<
  Exclude<Action, 'REQUEST' | 'CLOSE'>,
  TransferStatus[]
> = {
  ACCEPT: ['ACCEPTEE', 'EN_PREPARATION', 'PREPAREE', 'EN_TRANSIT', 'RECUE'],
  // PREPAREE n'y est PAS : tant que le transfert est préparable, une
  // préparation (correction comprise) se RÉAPPLIQUE — champ de document, sans
  // effet de stock. La reconnaître jetterait la correction en silence.
  PREPARE: ['EN_TRANSIT', 'RECUE'],
  SHIP: ['EN_TRANSIT', 'RECUE'],
  RECEIVE: ['RECUE'],
};

/// Transferts hors-ligne : chaque étape (demande au magasin, prise en charge,
/// préparation, expédition au dépôt, réception au magasin, refus/annulation)
/// passe par le MÊME cœur que sa route en ligne (`TransfersService`, verrou
/// `lockTransfer`, mouvements par le journal, anti-négatif au dépôt).
@Injectable()
export class TransferHandler implements SyncMutationHandler<TransferPayload> {
  readonly operationType = OperationType.TRANSFER;
  /// Plancher commun ; le détail par étape est contrôlé dans `apply`.
  readonly requiredRoles: readonly RoleCode[] = [
    RoleCode.ADMIN,
    RoleCode.VENDEUR,
    RoleCode.MAGASINIER,
  ];
  readonly requiredPermissions: readonly PermissionCode[] = [];
  readonly auditEntityType = 'Transfer';
  readonly auditAction = AuditAction.UPDATE;

  constructor(
    private readonly transfers: TransfersService,
    private readonly prisma: PrismaService,
  ) {}

  async validate(payload: unknown): Promise<TransferPayload> {
    const raw = (payload ?? {}) as Record<string, unknown>;
    if (raw.action === 'REQUEST') {
      const { action: _action, ...body } = raw;
      const dto = await validatePayload(CreateTransferDto, body);
      return { action: 'REQUEST', clientMutationId: dto.clientMutationId, dto };
    }
    const { action, clientMutationId, transferId, ...body } = raw;
    const envelope = await validatePayload(StepEnvelopeDto, {
      action,
      clientMutationId,
      transferId,
    });
    const dtoClass: (new () => object) | null =
      envelope.action === 'PREPARE'
        ? PrepareTransferDto
        : envelope.action === 'RECEIVE'
          ? ReceiveTransferDto
          : envelope.action === 'CLOSE'
            ? CloseTransferDto
            : null;
    // Accepter, expédier : aucun corps — tout champ en plus est refusé.
    if (dtoClass === null && Object.keys(body).length > 0) {
      throw new BusinessException(
        ErrorCode.VALIDATION_FAILED,
        `Étape ${envelope.action} : aucun champ attendu en plus de transferId`,
        HttpStatus.UNPROCESSABLE_ENTITY,
      );
    }
    return {
      action: envelope.action as Exclude<Action, 'REQUEST'>,
      clientMutationId: envelope.clientMutationId,
      transferId: envelope.transferId,
      dto: dtoClass ? await validatePayload(dtoClass, body) : {},
    };
  }

  async apply(
    payload: TransferPayload,
    context: SyncMutationContext,
  ): Promise<SyncApplyResult> {
    if (payload.clientMutationId !== context.clientMutationId) {
      throw new BusinessException(
        ErrorCode.VALIDATION_FAILED,
        'La clé de l’étape doit être celle de la mutation',
        HttpStatus.UNPROCESSABLE_ENTITY,
      );
    }
    this.assertRights(payload.action, context);

    const { tx, user } = context;
    let transfer: TransferDto;
    let recognized = false;
    if (payload.action === 'REQUEST') {
      const replayed = await this.transfers.replay(tx, payload.dto, user);
      recognized = replayed !== null;
      transfer =
        replayed ??
        (await this.transfers.requestInTx(tx, payload.dto, user, null));
    } else {
      // Verrou pris AVANT le constat « déjà fait » : il vaut pour toute l'étape.
      const before = await TransfersService.lockTransfer(
        tx,
        payload.transferId,
      );
      if (payload.action === 'CLOSE') {
        // Règle auteur / dépôt AVANT toute reconnaissance : une clôture « déjà
        // faite » ne se fait pas attribuer à qui n'avait pas le droit de la faire.
        TransfersService.assertCanClose(
          before,
          payload.dto as CloseTransferDto,
          user,
        );
      }
      recognized = this.alreadyDone(payload, before, user.id);
      transfer = recognized
        ? TransfersService.toDto(before)
        : await this.step(payload, context);
    }
    return {
      entityId: transfer.id,
      serverState: { status: transfer.status, number: transfer.number },
      auditAction:
        payload.action === 'REQUEST'
          ? AuditAction.CREATE
          : payload.action === 'CLOSE'
            ? AuditAction.CANCEL
            : AuditAction.UPDATE,
      auditNewValue: {
        step: payload.action,
        number: transfer.number,
        status: transfer.status,
        // Même détail qu'en ligne : ce qui a été demandé, préparé, expédié, reçu.
        lines: transfer.lines.map((l) => ({
          productId: l.productId,
          requestedQuantity: l.requestedQuantity,
          preparedQuantity: l.preparedQuantity,
          shippedQuantity: l.shippedQuantity,
          receivedQuantity: l.receivedQuantity,
        })),
        ...(recognized ? { alreadyRecordedOnline: true } : { offline: true }),
      },
    };
  }

  private step(
    payload: Exclude<TransferPayload, { action: 'REQUEST' }>,
    { tx, user }: SyncMutationContext,
  ): Promise<TransferDto> {
    const id = payload.transferId;
    switch (payload.action) {
      case 'ACCEPT':
        return this.transfers.accept(id, user, null, tx);
      case 'PREPARE':
        return this.transfers.prepare(
          id,
          payload.dto as PrepareTransferDto,
          user,
          null,
          tx,
        );
      case 'SHIP':
        return this.transfers.ship(id, user, null, tx);
      case 'RECEIVE':
        return this.transfers.receive(
          id,
          payload.dto as ReceiveTransferDto,
          user,
          null,
          tx,
        );
      case 'CLOSE':
        return this.transfers.close(
          id,
          payload.dto as CloseTransferDto,
          user,
          null,
          tx,
        );
    }
  }

  /// L'étape est-elle DÉJÀ faite, et par CE membre ? Seule la même personne
  /// (sa réponse en ligne perdue) est reconnue. Faite par un autre : refus
  /// tracé — l'appareil ne croit pas son geste enregistré, l'Historique ne le
  /// lui attribue pas, et ses quantités ne sont pas jetées en silence.
  private alreadyDone(
    payload: Exclude<TransferPayload, { action: 'REQUEST' }>,
    before: {
      status: TransferStatus;
      preparedById: string | null;
      receivedById: string | null;
    },
    userId: string,
  ): boolean {
    const status = before.status;
    // Une clôture n'est jamais « reconnue » : le transfert ne garde pas QUI l'a
    // close — la reconnaître pourrait attribuer le geste d'un autre. Déjà close :
    // le service la refuse (transition invalide), refus tracé, sans effet.
    if (payload.action === 'CLOSE') return false;
    // Une préparation PARTIELLE (done: false) se rejoue telle quelle : sans
    // effet de stock, et son état cible n'est pas final.
    if (
      payload.action === 'PREPARE' &&
      (payload.dto as PrepareTransferDto).done === false
    ) {
      return false;
    }
    if (!REACHED[payload.action].includes(status)) return false;
    const doneBy =
      payload.action === 'RECEIVE' ? before.receivedById : before.preparedById;
    if (doneBy !== userId) {
      throw new BusinessException(
        ErrorCode.INVALID_STATE_TRANSITION,
        `Étape ${payload.action} déjà faite par un autre membre : votre saisie ` +
          'hors-ligne n’a pas été appliquée',
        HttpStatus.CONFLICT,
      );
    }
    return true;
  }

  /// Rôle ET permission de l'étape, exactement comme la route en ligne.
  private assertRights(action: Action, { user }: SyncMutationContext): void {
    const rights = STEP_RIGHTS[action];
    if (!rights.roles.some((role) => user.roles.includes(role))) {
      throw new BusinessException(
        ErrorCode.FORBIDDEN_ROLE,
        `Rôle insuffisant pour l’étape ${action} : ${rights.roles.join(' ou ')} requis`,
        HttpStatus.FORBIDDEN,
      );
    }
    if (!user.permissions.includes(rights.permission)) {
      throw new BusinessException(
        ErrorCode.FORBIDDEN_PERMISSION,
        `Permission manquante : ${rights.permission}`,
        HttpStatus.FORBIDDEN,
      );
    }
  }

  /// Seule la DEMANDE crée une entité sous sa clé (les étapes se reconnaissent
  /// par l'état atteint, sous le verrou du transfert).
  async existsForKey(clientMutationId: string, userId: string) {
    return (
      (await this.prisma.transfer.count({
        where: { clientMutationId, requestedById: userId },
      })) > 0
    );
  }
}
