import { HttpStatus, Injectable } from '@nestjs/common';
import { RoleCode } from '../../common/auth.decorators';
import { BusinessException } from '../../common/business.exception';
import { ErrorCode } from '../../common/error-codes';
import { PERMISSIONS, PermissionCode } from '../../common/permissions';
import { validatePayload } from '../../common/validate-payload';
import { AuditAction, OperationType } from '../../generated/prisma/enums';
import { PrismaService } from '../../prisma/prisma.service';
import { CreateQuoteDto } from '../../sales/dto/quote.dto';
import { QuotesService } from '../../sales/quotes.service';
import {
  SyncApplyResult,
  SyncMutationContext,
  SyncMutationHandler,
} from '../sync-mutation.handler';

/// Devis fait hors ligne (2026-11-15). MÊME cœur que `POST /quotes`
/// (`QuotesService.createInTx`) : prix au tarif du client, AUCUN mouvement de
/// stock (règle 15) ; le numéro DV-… est attribué ici, à la synchronisation.
@Injectable()
export class QuoteHandler implements SyncMutationHandler<CreateQuoteDto> {
  readonly operationType = OperationType.QUOTE;
  /// Strictement ce qu'exige `POST /api/quotes` en ligne.
  readonly requiredRoles: readonly RoleCode[] = [
    RoleCode.ADMIN,
    RoleCode.VENDEUR,
  ];
  readonly requiredPermissions: readonly PermissionCode[] = [
    PERMISSIONS.SALE_CREATE,
  ];
  readonly auditEntityType = 'Quote';
  readonly auditAction = AuditAction.CREATE;

  constructor(
    private readonly quotes: QuotesService,
    private readonly prisma: PrismaService,
  ) {}

  async existsForKey(clientMutationId: string, userId: string) {
    return (
      (await this.prisma.quote.count({
        where: { id: clientMutationId, userId },
      })) > 0
    );
  }

  validate(payload: unknown): Promise<CreateQuoteDto> {
    return validatePayload(CreateQuoteDto, payload);
  }

  async apply(
    payload: CreateQuoteDto,
    context: SyncMutationContext,
  ): Promise<SyncApplyResult> {
    if (payload.id !== context.clientMutationId) {
      throw new BusinessException(
        ErrorCode.VALIDATION_FAILED,
        'L’id du devis doit être la clé de la mutation',
        HttpStatus.UNPROCESSABLE_ENTITY,
      );
    }
    // Déjà créé en ligne (réponse perdue) : `createInTx` le rend tel quel.
    const quote = await this.quotes.createInTx(
      context.tx,
      payload,
      context.user,
      { userId: context.user.id },
    );
    return {
      entityId: quote.id,
      serverState: { number: quote.number, totalTtc: String(quote.totalTtc) },
      auditNewValue: {
        number: quote.number,
        totalTtc: quote.totalTtc,
        lines: quote.lines.length,
        offline: true,
      },
    };
  }
}
