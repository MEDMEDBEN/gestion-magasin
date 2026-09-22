import { HttpStatus, Injectable } from '@nestjs/common';
import { RoleCode } from '../../common/auth.decorators';
import { BusinessException } from '../../common/business.exception';
import { ErrorCode } from '../../common/error-codes';
import { PERMISSIONS, PermissionCode } from '../../common/permissions';
import { validatePayload } from '../../common/validate-payload';
import { AuditAction, OperationType } from '../../generated/prisma/enums';
import { PrismaService } from '../../prisma/prisma.service';
import { CreateReceptionDto } from '../../receptions/dto/reception.dto';
import { ReceptionsService } from '../../receptions/receptions.service';
import {
  plausibleDeviceTime,
  SyncApplyResult,
  SyncMutationContext,
  SyncMutationHandler,
} from '../sync-mutation.handler';

/// Réception fournisseur faite hors-ligne (spec §15 : « fonctionne
/// hors-ligne »). Payload = le MÊME corps que `POST /receptions`. MÊME cœur que
/// la route (`ReceptionsService.createInTx`) : surlivraison refusée, prix
/// d'achat pris de la COMMANDE (jamais du bon), hors commande réservé à
/// l'ADMIN, stock entré par le journal, dette fournisseur et coût mis à jour.
@Injectable()
export class ReceptionHandler implements SyncMutationHandler<CreateReceptionDto> {
  readonly operationType = OperationType.RECEPTION;
  /// Strictement ce qu'exige `POST /api/receptions` en ligne.
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
    private readonly receptions: ReceptionsService,
    private readonly prisma: PrismaService,
  ) {}

  validate(payload: unknown): Promise<CreateReceptionDto> {
    return validatePayload(CreateReceptionDto, payload);
  }

  async apply(
    payload: CreateReceptionDto,
    context: SyncMutationContext,
  ): Promise<SyncApplyResult> {
    // Une clé = une opération : celle du corps doit être celle de la mutation.
    if (payload.clientMutationId !== context.clientMutationId) {
      throw new BusinessException(
        ErrorCode.VALIDATION_FAILED,
        'La clé de la réception doit être celle de la mutation',
        HttpStatus.UNPROCESSABLE_ENTITY,
      );
    }
    // Réception déjà faite en ligne (réponse perdue) : reconnue, jamais refaite.
    const replayed = await this.receptions.replay(
      context.tx,
      payload,
      context.user,
    );
    const reception =
      replayed ??
      (await this.receptions.createInTx(
        context.tx,
        payload,
        context.user,
        null,
        plausibleDeviceTime(context.deviceTimestamp),
      ));
    return {
      entityId: reception.id,
      serverState: { number: reception.number },
      auditNewValue: {
        number: reception.number,
        purchaseOrderId: reception.purchaseOrderId,
        supplierId: reception.supplierId,
        locationId: reception.locationId,
        totalTtc: reception.totalTtc,
        // Même détail qu'en ligne : ce qui est entré, et à quel prix.
        lines: reception.lines.map((l) => ({
          productId: l.productId,
          receivedQuantity: l.receivedQuantity,
          unitPriceHt: l.unitPriceHt,
        })),
        ...(replayed ? { alreadyRecordedOnline: true } : { offline: true }),
      },
    };
  }

  async existsForKey(clientMutationId: string, userId: string) {
    return (
      (await this.prisma.reception.count({
        where: { clientMutationId, userId },
      })) > 0
    );
  }
}
