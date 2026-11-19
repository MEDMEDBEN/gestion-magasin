import { HttpStatus, Injectable } from '@nestjs/common';
import { BusinessException } from '../../common/business.exception';
import { ErrorCode } from '../../common/error-codes';
import { PrismaService } from '../../prisma/prisma.service';
import { RoleCode } from '../../common/auth.decorators';
import { PERMISSIONS, PermissionCode } from '../../common/permissions';
import { validatePayload } from '../../common/validate-payload';
import { AuditAction, OperationType } from '../../generated/prisma/enums';
import {
  CreateDirectPurchaseDto,
  DirectPurchaseService,
  directPurchaseKeys,
} from '../../receptions/direct-purchase';
import {
  plausibleDeviceTime,
  SyncApplyResult,
  SyncMutationContext,
  SyncMutationHandler,
} from '../sync-mutation.handler';

/// Achat direct fait HORS LIGNE (2026-11-19) — même cœur que
/// `POST /purchases/direct` : stock, dette et paiement en une transaction.
@Injectable()
export class DirectPurchaseHandler implements SyncMutationHandler<CreateDirectPurchaseDto> {
  readonly operationType = OperationType.PURCHASE_ORDER;
  readonly requiredRoles: readonly RoleCode[] = [
    RoleCode.ADMIN,
    RoleCode.MAGASINIER,
  ];
  readonly requiredPermissions: readonly PermissionCode[] = [
    PERMISSIONS.RECEPTION_CREATE,
  ];
  readonly auditEntityType = 'Reception';
  readonly auditAction = AuditAction.CREATE;

  constructor(
    private readonly purchases: DirectPurchaseService,
    private readonly prisma: PrismaService,
  ) {}

  /// Déjà enregistré EN LIGNE (course réponse perdue / synchro) : « réessayer »,
  /// jamais un rejet définitif — sinon on referait l'achat en double.
  async existsForKey(clientMutationId: string, userId: string) {
    return (
      (await this.prisma.reception.count({
        where: {
          clientMutationId: {
            in: Object.values(directPurchaseKeys(clientMutationId)),
          },
          userId,
        },
      })) > 0
    );
  }

  validate(payload: unknown): Promise<CreateDirectPurchaseDto> {
    return validatePayload(CreateDirectPurchaseDto, payload);
  }

  async apply(
    payload: CreateDirectPurchaseDto,
    context: SyncMutationContext,
  ): Promise<SyncApplyResult> {
    if (payload.clientMutationId !== context.clientMutationId) {
      throw new BusinessException(
        ErrorCode.VALIDATION_FAILED,
        'La clé de l’achat doit être celle de la mutation',
        HttpStatus.UNPROCESSABLE_ENTITY,
      );
    }
    const done =
      (await this.purchases.replay(context.tx, payload, context.user)) ??
      (await this.purchases.createInTx(
        context.tx,
        payload,
        context.user,
        null,
        plausibleDeviceTime(context.deviceTimestamp),
      ));
    const first = done.receptions[0];
    return {
      entityId: first.id,
      serverState: {
        numbers: done.receptions.map((r) => r.number).join(', '),
      },
      // Trace complète (règle 7) : chaque réception, ses lignes, le payé.
      auditNewValue: {
        supplierId: payload.supplierId,
        paidAmount: payload.paidAmount ?? 0,
        receptions: done.receptions.map((r) => ({
          id: r.id,
          number: r.number,
          locationId: r.locationId,
          lines: r.lines.map((l) => ({
            productId: l.productId,
            receivedQuantity: l.receivedQuantity,
            unitPriceHt: l.unitPriceHt,
          })),
        })),
        offline: true,
      },
    };
  }
}
