import {
  Body,
  Controller,
  Get,
  HttpCode,
  HttpStatus,
  Ip,
  Param,
  Post,
  Query,
} from '@nestjs/common';
import {
  ApiBearerAuth,
  ApiConflictResponse,
  ApiCreatedResponse,
  ApiOkResponse,
  ApiOperation,
  ApiTags,
  ApiUnprocessableEntityResponse,
} from '@nestjs/swagger';
import { ActorContext } from '../audit/audit-writer';
import {
  AuthenticatedUser,
  CurrentUser,
  RequirePermissions,
  RoleCode,
  Roles,
} from '../common/auth.decorators';
import { CanonicalUuidPipe } from '../common/canonical-uuid.pipe';
import { ErrorResponseDto } from '../common/dto/error-response.dto';
import { PERMISSIONS } from '../common/permissions';
import {
  DeclareLossDto,
  LossQueryDto,
  MovementQueryDto,
  RejectLossDto,
  StockListDto,
  StockLossDto,
  StockLossListDto,
  StockMovementListDto,
  StockQueryDto,
} from './dto/stock.dto';
import { StockService } from './stock.service';

const ALL_ROLES = [RoleCode.ADMIN, RoleCode.VENDEUR, RoleCode.MAGASINIER];

const actorOf = (user: AuthenticatedUser, ip?: string): ActorContext => ({
  userId: user.id,
  ipAddress: ip,
});

@ApiTags('Stock')
@ApiBearerAuth()
@Controller('stock')
export class StockController {
  constructor(private readonly stockService: StockService) {}

  @Roles(...ALL_ROLES)
  @RequirePermissions(PERMISSIONS.STOCK_READ_STORE)
  @Get()
  @ApiOperation({
    summary: 'Stock par produit et emplacement',
    description:
      'Projection alimentée par les mouvements. Le stock hors magasin exige en plus `stock.read.warehouse`.',
  })
  @ApiOkResponse({ type: StockListDto })
  findAll(
    @Query() query: StockQueryDto,
    @CurrentUser() user: AuthenticatedUser,
  ): Promise<StockListDto> {
    return this.stockService.findStock(query, user);
  }

  @Roles(...ALL_ROLES)
  @RequirePermissions(PERMISSIONS.STOCK_READ_STORE)
  @Get('movements')
  @ApiOperation({
    summary: 'Journal des mouvements (source de vérité)',
    description: 'Historique immuable : aucun mouvement n’est jamais supprimé.',
  })
  @ApiOkResponse({ type: StockMovementListDto })
  movements(
    @Query() query: MovementQueryDto,
    @CurrentUser() user: AuthenticatedUser,
  ): Promise<StockMovementListDto> {
    return this.stockService.findMovements(query, user);
  }

  @Roles(RoleCode.ADMIN, RoleCode.MAGASINIER)
  @RequirePermissions(PERMISSIONS.STOCK_LOSS)
  @Get('losses')
  @ApiOperation({ summary: 'Déclarations de perte / casse' })
  @ApiOkResponse({ type: StockLossListDto })
  losses(@Query() query: LossQueryDto): Promise<StockLossListDto> {
    return this.stockService.findLosses(query);
  }

  @Roles(RoleCode.ADMIN, RoleCode.MAGASINIER)
  @RequirePermissions(PERMISSIONS.STOCK_LOSS)
  @Post('losses')
  @ApiOperation({
    summary: 'Déclare une perte ou une casse',
    description:
      'ADMIN (`stock.adjust.validate`) : appliquée tout de suite. MAGASINIER : EN_ATTENTE, ' +
      'le stock ne bouge qu’à la validation de l’admin.',
  })
  @ApiCreatedResponse({ type: StockLossDto })
  @ApiUnprocessableEntityResponse({
    type: ErrorResponseDto,
    description: '`STOCK_NEGATIVE` si appliquée sans stock suffisant',
  })
  declareLoss(
    @Body() dto: DeclareLossDto,
    @CurrentUser() user: AuthenticatedUser,
    @Ip() ip: string,
  ): Promise<StockLossDto> {
    return this.stockService.declareLoss(dto, user, actorOf(user, ip));
  }

  @Roles(RoleCode.ADMIN)
  @RequirePermissions(PERMISSIONS.STOCK_ADJUST_VALIDATE)
  @Post('losses/:id/validate')
  @HttpCode(HttpStatus.OK)
  @ApiOperation({
    summary: 'Valide une perte en attente (admin) : le stock baisse',
  })
  @ApiOkResponse({ type: StockLossDto })
  @ApiConflictResponse({
    type: ErrorResponseDto,
    description: '`INVALID_STATE_TRANSITION` : déjà traitée',
  })
  validateLoss(
    @Param('id', CanonicalUuidPipe) id: string,
    @CurrentUser() user: AuthenticatedUser,
    @Ip() ip: string,
  ): Promise<StockLossDto> {
    return this.stockService.validateLoss(id, user, actorOf(user, ip));
  }

  @Roles(RoleCode.ADMIN)
  @RequirePermissions(PERMISSIONS.STOCK_ADJUST_VALIDATE)
  @Post('losses/:id/reject')
  @HttpCode(HttpStatus.OK)
  @ApiOperation({
    summary: 'Refuse une perte en attente (admin) : le stock ne bouge pas',
  })
  @ApiOkResponse({ type: StockLossDto })
  rejectLoss(
    @Param('id', CanonicalUuidPipe) id: string,
    @Body() dto: RejectLossDto,
    @CurrentUser() user: AuthenticatedUser,
    @Ip() ip: string,
  ): Promise<StockLossDto> {
    return this.stockService.rejectLoss(id, dto, user, actorOf(user, ip));
  }
}
