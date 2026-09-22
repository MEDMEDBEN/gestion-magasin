import { HttpStatus, Injectable } from '@nestjs/common';
import { RoleCode } from '../../common/auth.decorators';
import { BusinessException } from '../../common/business.exception';
import { ErrorCode } from '../../common/error-codes';
import { PERMISSIONS, PermissionCode } from '../../common/permissions';
import { IsCanonicalUuid } from '../../common/validation';
import { validatePayload } from '../../common/validate-payload';
import { AuditAction, OperationType } from '../../generated/prisma/enums';
import { PrismaService } from '../../prisma/prisma.service';
import { CashSessionsService } from '../../sales/cash-sessions.service';
import {
  CloseCashSessionDto,
  OpenCashSessionDto,
} from '../../sales/dto/sale.dto';
import {
  plausibleDeviceTime,
  SyncApplyResult,
  SyncMutationContext,
  SyncMutationHandler,
} from '../sync-mutation.handler';

/// Clôture par la file : le corps de `POST /cash-sessions/:id/close` + la caisse.
class SyncCloseCashDto extends CloseCashSessionDto {
  @IsCanonicalUuid()
  sessionId!: string;
}

type CashPayload =
  | { action: 'OPEN'; dto: OpenCashSessionDto }
  | { action: 'CLOSE'; dto: SyncCloseCashDto };

/// Ouverture et clôture de caisse faites hors-ligne. MÊME cœur que les routes
/// en ligne (`CashSessionsService.openInTx` / `closeInTx`). Payload = le corps
/// de la route + `action` (`OPEN` | `CLOSE`) ; une clôture porte `sessionId`.
///
/// Ordre : la file d'un appareil part dans l'ordre de saisie — l'ouverture
/// avant les ventes qui la désignent (`cashSessionId`, id généré par
/// l'appareil), la clôture après elles : le rapport Z les compte toutes.
@Injectable()
export class CashSessionHandler implements SyncMutationHandler<CashPayload> {
  readonly operationType = OperationType.CASH_SESSION;
  /// Strictement ce qu'exigent `POST /cash-sessions` et `…/:id/close`.
  readonly requiredRoles: readonly RoleCode[] = [
    RoleCode.ADMIN,
    RoleCode.VENDEUR,
  ];
  readonly requiredPermissions: readonly PermissionCode[] = [
    PERMISSIONS.CASH_SESSION_MANAGE,
  ];
  readonly auditEntityType = 'CashSession';
  readonly auditAction = AuditAction.CREATE;

  constructor(
    private readonly cash: CashSessionsService,
    private readonly prisma: PrismaService,
  ) {}

  async validate(payload: unknown): Promise<CashPayload> {
    const { action, ...body } = (payload ?? {}) as Record<string, unknown>;
    if (action === 'OPEN') {
      return { action, dto: await validatePayload(OpenCashSessionDto, body) };
    }
    if (action === 'CLOSE') {
      return { action, dto: await validatePayload(SyncCloseCashDto, body) };
    }
    throw new BusinessException(
      ErrorCode.VALIDATION_FAILED,
      'action : OPEN ou CLOSE',
      HttpStatus.UNPROCESSABLE_ENTITY,
    );
  }

  async apply(
    payload: CashPayload,
    context: SyncMutationContext,
  ): Promise<SyncApplyResult> {
    // Une clé = une opération : celle du corps doit être celle de la mutation.
    if (payload.dto.clientMutationId !== context.clientMutationId) {
      throw new BusinessException(
        ErrorCode.VALIDATION_FAILED,
        'La clé de l’opération de caisse doit être celle de la mutation',
        HttpStatus.UNPROCESSABLE_ENTITY,
      );
    }
    if (payload.action === 'OPEN') {
      const replayed = await this.cash.replayOpen(
        context.tx,
        payload.dto,
        context.user,
      );
      // Ouverte à l'instant de l'APPAREIL (borné) : ses ventes hors-ligne,
      // datées de l'appareil, ne la précèdent pas dans le rapport Z.
      const session =
        replayed ??
        (await this.cash.openInTx(
          context.tx,
          payload.dto,
          context.user,
          null,
          plausibleDeviceTime(context.deviceTimestamp),
        ));
      return {
        entityId: session.id,
        serverState: { status: session.status },
        auditNewValue: {
          openingFloat: session.openingFloat,
          ...CashSessionHandler.origin(replayed !== null),
        },
      };
    }
    // La clôture reconnaît d'elle-même une clôture déjà faite sous cette clé ;
    // on le sait ici pour ne pas la tracer comme une clôture hors-ligne.
    const replayed =
      (await context.tx.cashSession.count({
        where: { closeMutationId: context.clientMutationId },
      })) > 0;
    const closed = await this.cash.closeInTx(
      context.tx,
      payload.dto.sessionId,
      payload.dto,
      context.user,
      null,
      plausibleDeviceTime(context.deviceTimestamp),
    );
    return {
      entityId: closed.id,
      serverState: {
        status: closed.status,
        expectedAmount: String(closed.expectedAmount),
        difference: String(closed.difference),
      },
      auditAction: AuditAction.VALIDATE,
      auditNewValue: {
        expectedAmount: closed.expectedAmount,
        countedAmount: closed.countedAmount,
        difference: closed.difference,
        ...CashSessionHandler.origin(replayed),
      },
    };
  }

  /// Opération faite hors-ligne, ou déjà enregistrée en ligne (réponse perdue)
  /// et seulement reconnue : le journal ne doit pas dire « hors-ligne » pour un
  /// geste fait en ligne (audit sécu tranche C).
  private static origin(replayed: boolean) {
    return replayed ? { alreadyRecordedOnline: true } : { offline: true };
  }

  async existsForKey(clientMutationId: string, userId: string) {
    const count = await this.prisma.cashSession.count({
      where: {
        userId,
        OR: [
          { openMutationId: clientMutationId },
          { closeMutationId: clientMutationId },
        ],
      },
    });
    return count > 0;
  }
}
