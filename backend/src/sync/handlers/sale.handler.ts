import { HttpStatus, Injectable } from '@nestjs/common';
import { RoleCode } from '../../common/auth.decorators';
import { BusinessException } from '../../common/business.exception';
import { ErrorCode } from '../../common/error-codes';
import { PERMISSIONS, PermissionCode } from '../../common/permissions';
import { validatePayload } from '../../common/validate-payload';
import { AuditAction, OperationType } from '../../generated/prisma/enums';
import { CreateSaleDto, SaleDto } from '../../sales/dto/sale.dto';
import { SalesService } from '../../sales/sales.service';
import { PrismaService } from '../../prisma/prisma.service';
import {
  plausibleDeviceTime,
  SyncApplyResult,
  SyncMutationContext,
  SyncMutationHandler,
} from '../sync-mutation.handler';

/// Payload `SALE` = le MÊME corps que `POST /sales` (`CreateSaleDto`), avec le
/// total encaissé OBLIGATOIRE (contrôlé dans `validate` : le `@IsOptional`
/// hérité resterait actif sur un DTO dérivé). Le prix de chaque ligne est celui
/// que l'appareil affichait (décision 2026-09-22), accepté s'il respecte le
/// plancher (coût d'achat) ; un écart de TOTAL ne vient plus que de la TVA.
///
/// Vente (TICKET) faite hors-ligne. MÊME cœur que `POST /sales`
/// (`SalesService.createInTx`) : stock revalidé (anti-négatif), prix de
/// l'appareil (plancher : coût d'achat), caisse de la vente, plafond de crédit. Une facture ne
/// passe jamais par ici : son numéro légal s'attribue en ligne (règle 11).
@Injectable()
export class SaleHandler implements SyncMutationHandler<CreateSaleDto> {
  readonly operationType = OperationType.SALE;
  /// Strictement ce qu'exige `POST /api/sales` en ligne.
  readonly requiredRoles: readonly RoleCode[] = [
    RoleCode.ADMIN,
    RoleCode.VENDEUR,
  ];
  readonly requiredPermissions: readonly PermissionCode[] = [
    PERMISSIONS.SALE_CREATE,
  ];
  readonly auditEntityType = 'Sale';
  readonly auditAction = AuditAction.CREATE;

  constructor(
    private readonly sales: SalesService,
    private readonly prisma: PrismaService,
  ) {}

  async existsForKey(clientMutationId: string, userId: string) {
    return (
      (await this.prisma.sale.count({ where: { clientMutationId, userId } })) >
      0
    );
  }

  async validate(payload: unknown): Promise<CreateSaleDto> {
    const sale = await validatePayload(CreateSaleDto, payload);
    if (sale.paidAmount > 0 && sale.cashSessionId === undefined) {
      throw new BusinessException(
        ErrorCode.VALIDATION_FAILED,
        'cashSessionId : la caisse des espèces est obligatoire hors-ligne',
        HttpStatus.UNPROCESSABLE_ENTITY,
      );
    }
    if (sale.expectedTotalTtc === undefined) {
      throw new BusinessException(
        ErrorCode.VALIDATION_FAILED,
        'expectedTotalTtc : total encaissé sur l’appareil obligatoire hors-ligne',
        HttpStatus.UNPROCESSABLE_ENTITY,
      );
    }
    return sale;
  }

  async apply(
    payload: CreateSaleDto,
    context: SyncMutationContext,
  ): Promise<SyncApplyResult> {
    // La vente et la mutation partagent UNE clé : c'est ce qui permet de
    // reconnaître une vente déjà créée en ligne. Une clé différente dans le
    // corps désignerait une autre opération.
    if (payload.clientMutationId !== context.clientMutationId) {
      throw new BusinessException(
        ErrorCode.VALIDATION_FAILED,
        'La clé de la vente doit être celle de la mutation',
        HttpStatus.UNPROCESSABLE_ENTITY,
      );
    }
    const already = await this.sales.replay(context.tx, payload, context.user);
    const sale =
      already ??
      (await this.sales.createInTx(
        context.tx,
        payload,
        context.user,
        plausibleDeviceTime(context.deviceTimestamp),
        true,
      ));
    return {
      entityId: sale.id,
      serverState: {
        number: sale.number,
        totalTtc: String(sale.totalTtc),
        soldAt: sale.soldAt.toISOString(),
      },
      auditNewValue: SaleHandler.audit(sale, payload, already !== null),
    };
  }

  private static audit(sale: SaleDto, dto: CreateSaleDto, recognized: boolean) {
    return {
      number: sale.number,
      totalTtc: sale.totalTtc,
      paidAmount: sale.paidAmount,
      customerId: sale.customerId,
      lines: sale.lines.length,
      offline: true,
      priceOverrides: SalesService.priceOverrides(sale, dto),
      ...(recognized && { alreadyRecordedOnline: true }),
    };
  }
}
