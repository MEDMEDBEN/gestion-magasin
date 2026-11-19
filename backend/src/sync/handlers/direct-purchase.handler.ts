import { Injectable } from '@nestjs/common';
import { RoleCode } from '../../common/auth.decorators';
import { PERMISSIONS, PermissionCode } from '../../common/permissions';
import { validatePayload } from '../../common/validate-payload';
import { AuditAction, OperationType } from '../../generated/prisma/enums';
import {
  CreateDirectPurchaseDto,
  DirectPurchaseService,
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

  constructor(private readonly purchases: DirectPurchaseService) {}

  validate(payload: unknown): Promise<CreateDirectPurchaseDto> {
    return validatePayload(CreateDirectPurchaseDto, payload);
  }

  async apply(
    payload: CreateDirectPurchaseDto,
    context: SyncMutationContext,
  ): Promise<SyncApplyResult> {
    const done =
      (await this.purchases.replay(context.tx, payload)) ??
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
      auditNewValue: {
        supplierId: payload.supplierId,
        lines: payload.lines.length,
        paidAmount: payload.paidAmount ?? 0,
        offline: true,
      },
    };
  }
}
