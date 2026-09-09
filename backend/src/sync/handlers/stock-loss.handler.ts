import { HttpStatus, Injectable } from '@nestjs/common';
import { BusinessException } from '../../common/business.exception';
import { ErrorCode } from '../../common/error-codes';
import { RoleCode } from '../../common/auth.decorators';
import { PERMISSIONS, PermissionCode } from '../../common/permissions';
import { parseQuantity } from '../../common/quantity';
import { validatePayload } from '../../common/validate-payload';
import { AuditAction, OperationType } from '../../generated/prisma/enums';
import { StockLedgerService } from '../../stock/stock-ledger.service';
import { StockLossPayloadDto } from '../dto/mutation-payloads.dto';
import {
  SyncApplyResult,
  SyncMutationContext,
  SyncMutationHandler,
} from '../sync-mutation.handler';

/// Perte / casse constatée au dépôt, saisie hors-ligne. Première opération branchée sur
/// le contrat de sync : elle en exerce toutes les règles — permission serveur, validation
/// du payload, anti-stock-négatif, mouvement + projection atomiques, audit, idempotence.
@Injectable()
export class StockLossHandler implements SyncMutationHandler<StockLossPayloadDto> {
  readonly operationType = OperationType.MANUAL;
  /// Strictement ce qu'exige `POST /api/stock/losses` en ligne.
  readonly requiredRoles: readonly RoleCode[] = [RoleCode.ADMIN, RoleCode.MAGASINIER];
  readonly requiredPermissions: readonly PermissionCode[] = [PERMISSIONS.STOCK_LOSS];
  readonly auditEntityType = 'StockMovement';
  readonly auditAction = AuditAction.ADJUST;

  constructor(private readonly ledger: StockLedgerService) {}

  validate(payload: unknown): Promise<StockLossPayloadDto> {
    return validatePayload(StockLossPayloadDto, payload);
  }

  async apply(
    payload: StockLossPayloadDto,
    context: SyncMutationContext,
  ): Promise<SyncApplyResult> {
    const quantity = parseQuantity(payload.quantity);
    if (quantity.lessThanOrEqualTo(0)) {
      throw new BusinessException(
        ErrorCode.VALIDATION_FAILED,
        'La quantité perdue doit être strictement positive',
        HttpStatus.UNPROCESSABLE_ENTITY,
      );
    }

    const applied = await this.ledger.applyMovement(context.tx, {
      movementId: payload.id,
      productId: payload.productId,
      locationId: payload.locationId,
      // Une perte est une SORTIE : le delta appliqué est négatif.
      quantity: quantity.negated(),
      type: payload.type,
      operationType: this.operationType,
      operationId: payload.id ?? null,
      userId: context.user.id,
      comment: payload.comment ?? null,
    });

    return {
      entityId: applied.movementId,
      serverState: {
        productId: payload.productId,
        locationId: payload.locationId,
        quantityAfter: applied.quantityAfter,
        availableAfter: applied.availableAfter,
      },
    };
  }
}
