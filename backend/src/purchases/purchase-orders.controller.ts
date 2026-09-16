import {
  Body,
  Controller,
  Get,
  HttpCode,
  HttpStatus,
  Ip,
  Param,
  Patch,
  Post,
  Query,
  UseGuards,
} from '@nestjs/common';
import {
  ApiBearerAuth,
  ApiConflictResponse,
  ApiCreatedResponse,
  ApiOkResponse,
  ApiOperation,
  ApiTags,
} from '@nestjs/swagger';
import {
  AuthenticatedUser,
  CurrentUser,
  RequirePermissions,
  RoleCode,
  Roles,
} from '../common/auth.decorators';
import { CanonicalUuidPipe } from '../common/canonical-uuid.pipe';
import { ErrorResponseDto } from '../common/dto/error-response.dto';
import { FreshAccessGuard } from '../common/fresh-access.guard';
import { PERMISSIONS } from '../common/permissions';
import {
  CreatePurchaseOrderDto,
  PurchaseOrderDto,
  PurchaseOrderListDto,
  PurchaseOrderListQueryDto,
  UpdatePurchaseOrderDto,
} from './dto/purchase-order.dto';
import { PurchaseOrdersService } from './purchase-orders.service';

@ApiTags('Achats')
@ApiBearerAuth()
@Controller('purchase-orders')
export class PurchaseOrdersController {
  constructor(private readonly orders: PurchaseOrdersService) {}

  @Roles(RoleCode.ADMIN, RoleCode.MAGASINIER)
  @RequirePermissions(PERMISSIONS.PURCHASE_CREATE)
  @UseGuards(FreshAccessGuard)
  @Post()
  @ApiOperation({
    summary: 'Crée une commande fournisseur (admin ou magasinier)',
    description:
      'Statut BROUILLON. Numéro `BC-AAAA-NNNNN` attribué serveur. Prix d’achat et ' +
      'TVA figés sur les lignes. La DETTE fournisseur ne bouge qu’à la réception.',
  })
  @ApiCreatedResponse({ type: PurchaseOrderDto })
  create(
    @Body() dto: CreatePurchaseOrderDto,
    @CurrentUser() user: AuthenticatedUser,
    @Ip() ip: string,
  ): Promise<PurchaseOrderDto> {
    return this.orders.create(dto, user, { userId: user.id, ipAddress: ip });
  }

  @Roles(RoleCode.ADMIN, RoleCode.MAGASINIER)
  @RequirePermissions(PERMISSIONS.PURCHASE_CREATE)
  @Get()
  @ApiOperation({
    summary: 'Commandes fournisseurs (filtres statut, fournisseur)',
  })
  @ApiOkResponse({ type: PurchaseOrderListDto })
  findAll(
    @Query() query: PurchaseOrderListQueryDto,
  ): Promise<PurchaseOrderListDto> {
    return this.orders.findAll(query);
  }

  @Roles(RoleCode.ADMIN, RoleCode.MAGASINIER)
  @RequirePermissions(PERMISSIONS.PURCHASE_CREATE)
  @Get(':id')
  @ApiOperation({ summary: 'Détail d’une commande (lignes, reste à recevoir)' })
  @ApiOkResponse({ type: PurchaseOrderDto })
  findOne(
    @Param('id', CanonicalUuidPipe) id: string,
  ): Promise<PurchaseOrderDto> {
    return this.orders.findOne(id);
  }

  @Roles(RoleCode.ADMIN, RoleCode.MAGASINIER)
  @RequirePermissions(PERMISSIONS.PURCHASE_CREATE)
  @UseGuards(FreshAccessGuard)
  @Patch(':id')
  @ApiOperation({
    summary: 'Modifie une commande non confirmée (lignes remplacées)',
    description:
      'Possible tant que la commande est BROUILLON ou COMMANDEE ; au-delà, seule ' +
      'l’annulation reste ouverte (`INVALID_STATE_TRANSITION`).',
  })
  @ApiOkResponse({ type: PurchaseOrderDto })
  @ApiConflictResponse({ type: ErrorResponseDto })
  update(
    @Param('id', CanonicalUuidPipe) id: string,
    @Body() dto: UpdatePurchaseOrderDto,
    @CurrentUser() user: AuthenticatedUser,
    @Ip() ip: string,
  ): Promise<PurchaseOrderDto> {
    return this.orders.update(id, dto, { userId: user.id, ipAddress: ip });
  }

  @Roles(RoleCode.ADMIN)
  @RequirePermissions(PERMISSIONS.PURCHASE_CONFIRM)
  @UseGuards(FreshAccessGuard)
  @Post(':id/confirm')
  @HttpCode(HttpStatus.OK)
  @ApiOperation({
    summary: 'Confirme une commande (ADMIN SEUL)',
    description:
      'Idempotent : une commande déjà confirmée est rendue telle quelle.',
  })
  @ApiOkResponse({ type: PurchaseOrderDto })
  confirm(
    @Param('id', CanonicalUuidPipe) id: string,
    @CurrentUser() user: AuthenticatedUser,
    @Ip() ip: string,
  ): Promise<PurchaseOrderDto> {
    return this.orders.confirm(id, user, { userId: user.id, ipAddress: ip });
  }

  @Roles(RoleCode.ADMIN)
  @RequirePermissions(PERMISSIONS.PURCHASE_CONFIRM)
  @UseGuards(FreshAccessGuard)
  @Post(':id/cancel')
  @HttpCode(HttpStatus.OK)
  @ApiOperation({
    summary: 'Annule une commande (ADMIN SEUL)',
    description:
      'Pas de suppression (règle 7). Refusée dès qu’une réception existe.',
  })
  @ApiOkResponse({ type: PurchaseOrderDto })
  @ApiConflictResponse({ type: ErrorResponseDto })
  cancel(
    @Param('id', CanonicalUuidPipe) id: string,
    @CurrentUser() user: AuthenticatedUser,
    @Ip() ip: string,
  ): Promise<PurchaseOrderDto> {
    return this.orders.cancel(id, { userId: user.id, ipAddress: ip });
  }
}
