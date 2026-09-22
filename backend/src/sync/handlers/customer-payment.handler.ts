import { HttpStatus, Injectable } from '@nestjs/common';
import { RoleCode } from '../../common/auth.decorators';
import { BusinessException } from '../../common/business.exception';
import { ErrorCode } from '../../common/error-codes';
import { PERMISSIONS, PermissionCode } from '../../common/permissions';
import { validatePayload } from '../../common/validate-payload';
import { CustomersService } from '../../customers/customers.service';
import { CreateCustomerPaymentDto } from '../../customers/dto/customer.dto';
import { AuditAction, OperationType } from '../../generated/prisma/enums';
import { PrismaService } from '../../prisma/prisma.service';
import {
  plausibleDeviceTime,
  SyncApplyResult,
  SyncMutationContext,
  SyncMutationHandler,
} from '../sync-mutation.handler';

/// Règlement d'une dette client fait hors-ligne (espèces). Payload = le MÊME
/// corps que `POST /payments/customer`, avec la caisse OBLIGATOIRE
/// (`cashSessionId`, comme la vente en espèces : jamais imputé à une autre
/// caisse). MÊME cœur que la route (`CustomersService.payInTx`) : jamais
/// au-delà de la dette ni du reste dû de la vente, calculés AU SYNC.
@Injectable()
export class CustomerPaymentHandler implements SyncMutationHandler<CreateCustomerPaymentDto> {
  readonly operationType = OperationType.CUSTOMER_PAYMENT;
  /// Strictement ce qu'exige `POST /api/payments/customer` en ligne.
  readonly requiredRoles: readonly RoleCode[] = [
    RoleCode.ADMIN,
    RoleCode.VENDEUR,
  ];
  readonly requiredPermissions: readonly PermissionCode[] = [
    PERMISSIONS.CUSTOMER_PAYMENT_CREATE,
  ];
  readonly auditEntityType = 'CustomerPayment';
  readonly auditAction = AuditAction.CREATE;

  constructor(
    private readonly customers: CustomersService,
    private readonly prisma: PrismaService,
  ) {}

  async validate(payload: unknown): Promise<CreateCustomerPaymentDto> {
    const dto = await validatePayload(CreateCustomerPaymentDto, payload);
    if (dto.cashSessionId === undefined) {
      throw new BusinessException(
        ErrorCode.VALIDATION_FAILED,
        'cashSessionId : la caisse des espèces est obligatoire hors-ligne',
        HttpStatus.UNPROCESSABLE_ENTITY,
      );
    }
    return dto;
  }

  async apply(
    payload: CreateCustomerPaymentDto,
    context: SyncMutationContext,
  ): Promise<SyncApplyResult> {
    // Une clé = une opération : celle du corps doit être celle de la mutation.
    if (payload.clientMutationId !== context.clientMutationId) {
      throw new BusinessException(
        ErrorCode.VALIDATION_FAILED,
        'La clé du règlement doit être celle de la mutation',
        HttpStatus.UNPROCESSABLE_ENTITY,
      );
    }
    const replayed = await this.customers.replayPayment(
      context.tx,
      payload,
      context.user,
    );
    const payment =
      replayed ??
      (await this.customers.payInTx(
        context.tx,
        payload,
        context.user,
        null,
        plausibleDeviceTime(context.deviceTimestamp),
      ));
    return {
      entityId: payment.id,
      serverState: { balanceDue: String(payment.balanceDue) },
      auditNewValue: {
        customerId: payment.customerId,
        amount: payment.amount,
        saleId: payment.saleId,
        ...(replayed ? { alreadyRecordedOnline: true } : { offline: true }),
      },
    };
  }

  async existsForKey(clientMutationId: string, userId: string) {
    return (
      (await this.prisma.customerPayment.count({
        where: { clientMutationId, userId },
      })) > 0
    );
  }
}
