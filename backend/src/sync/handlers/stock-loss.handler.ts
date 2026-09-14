import { Injectable } from '@nestjs/common';
import { RoleCode } from '../../common/auth.decorators';
import { PERMISSIONS, PermissionCode } from '../../common/permissions';
import { validatePayload } from '../../common/validate-payload';
import { AuditAction, OperationType } from '../../generated/prisma/enums';
import { StockService } from '../../stock/stock.service';
import { StockLossPayloadDto } from '../dto/mutation-payloads.dto';
import {
  SyncApplyResult,
  SyncMutationContext,
  SyncMutationHandler,
} from '../sync-mutation.handler';

/// Perte / casse saisie hors-ligne. Même règle qu'en ligne (`POST /stock/losses`),
/// par le MÊME code (`StockService.declareLossInTx`) : l'ADMIN applique tout de
/// suite, le MAGASINIER crée une déclaration EN ATTENTE de validation.
@Injectable()
export class StockLossHandler implements SyncMutationHandler<StockLossPayloadDto> {
  readonly operationType = OperationType.MANUAL;
  /// Strictement ce qu'exige `POST /api/stock/losses` en ligne.
  readonly requiredRoles: readonly RoleCode[] = [
    RoleCode.ADMIN,
    RoleCode.MAGASINIER,
  ];
  readonly requiredPermissions: readonly PermissionCode[] = [
    PERMISSIONS.STOCK_LOSS,
  ];
  readonly auditEntityType = 'StockLossDeclaration';
  readonly auditAction = AuditAction.CREATE;

  constructor(private readonly stock: StockService) {}

  validate(payload: unknown): Promise<StockLossPayloadDto> {
    return validatePayload(StockLossPayloadDto, payload);
  }

  async apply(
    payload: StockLossPayloadDto,
    context: SyncMutationContext,
  ): Promise<SyncApplyResult> {
    const loss = await this.stock.declareLossInTx(
      context.tx,
      {
        id: payload.id,
        productId: payload.productId,
        locationId: payload.locationId,
        quantity: payload.quantity,
        comment: payload.comment ?? null,
      },
      context.user,
    );
    const serverState: Record<string, string> = {
      productId: loss.productId,
      locationId: loss.locationId,
      status: loss.status,
    };
    if (loss.movementId) {
      const stock = await context.tx.stock.findUniqueOrThrow({
        where: {
          productId_locationId: {
            productId: loss.productId,
            locationId: loss.locationId,
          },
        },
      });
      const view = StockService.stockToDto(stock);
      serverState.quantityAfter = view.quantity;
      serverState.availableAfter = view.availableQuantity;
    }
    return { entityId: loss.id, serverState };
  }
}
