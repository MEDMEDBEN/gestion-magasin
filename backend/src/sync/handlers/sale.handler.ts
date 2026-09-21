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
  SyncApplyResult,
  SyncMutationContext,
  SyncMutationHandler,
} from '../sync-mutation.handler';

/// Au-delà, l'instant de l'appareil n'est plus cru : la vente est datée de sa
/// synchronisation. Même valeur que `AppConfig.maxOfflineDuration`, mais pas la
/// même mesure (l'app mesure l'âge de la file au moment de saisir). Borne
/// l'antidatage par un appel direct à /sync ; une vente en espèces est de plus
/// bornée par l'ouverture de sa caisse (`CASH_SESSION_CLOSED`).
const MAX_OFFLINE_MS = 72 * 3600 * 1000;

/// Payload `SALE` = le MÊME corps que `POST /sales` (`CreateSaleDto`), avec le
/// total encaissé OBLIGATOIRE (contrôlé dans `validate` : le `@IsOptional`
/// hérité resterait actif sur un DTO dérivé). Le prix n'est jamais accepté de
/// l'appareil : recalculé au tarif COURANT, un écart → `SALE_TOTAL_CHANGED`.
///
/// Vente (TICKET) faite hors-ligne. MÊME cœur que `POST /sales`
/// (`SalesService.createInTx`) : stock revalidé (anti-négatif), prix du tarif
/// courant, caisse ouverte pour les espèces, plafond de crédit. Une facture ne
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

  async existsForKey(clientMutationId: string): Promise<boolean> {
    return (await this.prisma.sale.count({ where: { clientMutationId } })) > 0;
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
        SaleHandler.soldAt(context.deviceTimestamp),
      ));
    return {
      entityId: sale.id,
      serverState: {
        number: sale.number,
        totalTtc: String(sale.totalTtc),
        soldAt: sale.soldAt.toISOString(),
      },
      auditNewValue: SaleHandler.audit(sale, already !== null),
    };
  }

  /// Instant de la vente : celui de l'appareil s'il est plausible — ni dans le
  /// futur, ni plus ancien que la durée hors-ligne permise.
  static soldAt(deviceTimestamp: Date, now = new Date()): Date {
    const age = now.getTime() - deviceTimestamp.getTime();
    return age >= 0 && age <= MAX_OFFLINE_MS ? deviceTimestamp : now;
  }

  private static audit(sale: SaleDto, recognized: boolean) {
    return {
      number: sale.number,
      totalTtc: sale.totalTtc,
      paidAmount: sale.paidAmount,
      customerId: sale.customerId,
      lines: sale.lines.length,
      offline: true,
      ...(recognized && { alreadyRecordedOnline: true }),
    };
  }
}
