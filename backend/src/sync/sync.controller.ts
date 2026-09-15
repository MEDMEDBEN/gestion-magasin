import {
  Body,
  Controller,
  HttpCode,
  HttpStatus,
  Ip,
  Post,
  UseGuards,
} from '@nestjs/common';
import {
  ApiBearerAuth,
  ApiOkResponse,
  ApiOperation,
  ApiTags,
} from '@nestjs/swagger';
import {
  AuthenticatedUser,
  CurrentUser,
  RoleCode,
  Roles,
} from '../common/auth.decorators';
import { FreshAccessGuard } from '../common/fresh-access.guard';
import { SyncBatchDto, SyncBatchResultDto } from './dto/sync.dto';
import { SyncService } from './sync.service';

/// Point d'entrée unique des opérations créées hors connexion (docs/context.md).
@ApiTags('Synchronisation')
@ApiBearerAuth()
@Controller('sync')
export class SyncController {
  constructor(private readonly syncService: SyncService) {}

  /// Les trois rôles synchronisent — chacun ses opérations. La permission n'est donc PAS
  /// portée par la route mais par CHAQUE mutation : le handler de l'opération exige
  /// exactement les mêmes permissions qu'en ligne, et une mutation non autorisée est
  /// rejetée individuellement sans faire échouer le lot.
  @Roles(RoleCode.ADMIN, RoleCode.VENDEUR, RoleCode.MAGASINIER)
  // Un lot peut modifier le stock : rôles et permissions relus EN BASE une fois par
  // lot (compte actif, session vivante) — jamais ceux d'un token de 15 min.
  @UseGuards(FreshAccessGuard)
  @Post()
  @HttpCode(HttpStatus.OK)
  @ApiOperation({
    summary: 'Applique un lot de mutations hors-ligne (idempotent)',
    description:
      'Rejoue les mutations dans l’ordre du timestamp appareil. Chaque mutation est ' +
      'traitée dans SA transaction : `CONFIRMEE` (appliquée) ou `REJETEE` (rien appliqué, ' +
      'motif lisible) — ces deux résultats sont définitifs et mémorisés sur ' +
      '`clientMutationId`, un renvoi ne réapplique jamais rien. `NON_TRAITEE` signale au ' +
      'contraire une mutation à garder en file et à renvoyer. ' +
      'Anti-stock-négatif : une opération qui rendrait le disponible négatif est rejetée ' +
      '(`STOCK_NEGATIVE`), sauf produit en `allowBackorder`.',
  })
  @ApiOkResponse({ type: SyncBatchResultDto })
  push(
    @Body() dto: SyncBatchDto,
    @CurrentUser() user: AuthenticatedUser,
    @Ip() ip: string,
  ): Promise<SyncBatchResultDto> {
    return this.syncService.processBatch(dto, user, ip);
  }
}
