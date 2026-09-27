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
  StreamableFile,
} from '@nestjs/common';
import {
  ApiBearerAuth,
  ApiConflictResponse,
  ApiCreatedResponse,
  ApiOkResponse,
  ApiOperation,
  ApiTags,
  ApiProduces,
} from '@nestjs/swagger';
import { Throttle } from '@nestjs/throttler';
import {
  AuthenticatedUser,
  CurrentUser,
  RequireFreshAccess,
  RequirePermissions,
  RoleCode,
  Roles,
} from '../common/auth.decorators';
import { CanonicalUuidPipe } from '../common/canonical-uuid.pipe';
import { ErrorResponseDto } from '../common/dto/error-response.dto';
import { PERMISSIONS } from '../common/permissions';
import {
  ClosePurchaseOrderDto,
  ConfirmPurchaseOrderDto,
  CreatePurchaseOrderDto,
  PurchaseOrderDto,
  PurchaseOrderListDto,
  PurchaseOrderExportQueryDto,
  PurchaseOrderListQueryDto,
  UpdatePurchaseOrderDto,
} from './dto/purchase-order.dto';
import {
  EXPORT_THROTTLE,
  EXPORT_TYPES,
  exportResponse,
  renderExport,
} from '../common/export/export';
import { PurchaseOrdersService } from './purchase-orders.service';

@ApiTags('Achats')
@ApiBearerAuth()
@Controller('purchase-orders')
export class PurchaseOrdersController {
  constructor(private readonly orders: PurchaseOrdersService) {}

  @Roles(RoleCode.ADMIN, RoleCode.MAGASINIER)
  @RequirePermissions(PERMISSIONS.PURCHASE_CREATE)
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

  /// Export : MÊMES gardes que `GET /purchase-orders`, mêmes lignes.
  /// Déclarée AVANT `:id`, sinon « export » serait lu comme un identifiant.
  @Roles(RoleCode.ADMIN, RoleCode.MAGASINIER)
  @RequirePermissions(PERMISSIONS.PURCHASE_CREATE)
  // Droits relus EN BASE : plus strict que la liste — un admin rétrogradé
  // n'extrait pas toute la base pendant les 15 min de son jeton.
  @RequireFreshAccess()
  @Throttle(EXPORT_THROTTLE)
  @Get('export')
  @ApiOperation({ summary: 'Commandes fournisseurs en Excel, CSV ou PDF' })
  @ApiProduces(...EXPORT_TYPES)
  @ApiOkResponse({ schema: { type: 'string', format: 'binary' } })
  async export(
    @Query() query: PurchaseOrderExportQueryDto,
  ): Promise<StreamableFile> {
    return exportResponse(
      await renderExport(await this.orders.exportDocument(query), query.format),
    );
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

  /// Bon de commande PDF, à envoyer au fournisseur. MÊMES gardes que le détail.
  @Roles(RoleCode.ADMIN, RoleCode.MAGASINIER)
  @RequirePermissions(PERMISSIONS.PURCHASE_CREATE)
  // Rendu synchrone : bridé comme les autres documents.
  @Throttle({ default: { ttl: 60_000, limit: 30 } })
  @Get(':id/pdf')
  @ApiOperation({ summary: 'Bon de commande fournisseur (PDF A4)' })
  @ApiProduces('application/pdf')
  @ApiOkResponse({ schema: { type: 'string', format: 'binary' } })
  async document(
    @Param('id', CanonicalUuidPipe) id: string,
  ): Promise<StreamableFile> {
    const { filename, pdf } = await this.orders.renderDocument(id);
    return new StreamableFile(pdf, {
      type: 'application/pdf',
      disposition: `inline; filename="${filename}"`,
    });
  }

  @Roles(RoleCode.ADMIN, RoleCode.MAGASINIER)
  @RequirePermissions(PERMISSIONS.PURCHASE_CREATE)
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
  @Post(':id/confirm')
  @HttpCode(HttpStatus.OK)
  @ApiOperation({
    summary: 'Confirme une commande (ADMIN SEUL)',
    description:
      'Idempotent : une commande déjà confirmée est rendue telle quelle. ' +
      '`expectedUpdatedAt` différent de la version en base → 409 `CONFLICT`.',
  })
  @ApiOkResponse({ type: PurchaseOrderDto })
  @ApiConflictResponse({ type: ErrorResponseDto })
  confirm(
    @Param('id', CanonicalUuidPipe) id: string,
    @Body() dto: ConfirmPurchaseOrderDto,
    @CurrentUser() user: AuthenticatedUser,
    @Ip() ip: string,
  ): Promise<PurchaseOrderDto> {
    return this.orders.confirm(id, dto, user, {
      userId: user.id,
      ipAddress: ip,
    });
  }

  @Roles(RoleCode.ADMIN)
  @RequirePermissions(PERMISSIONS.PURCHASE_CONFIRM)
  @Post(':id/close')
  @HttpCode(HttpStatus.OK)
  @ApiOperation({
    summary:
      'Clôture le reliquat d’une commande partiellement reçue (ADMIN SEUL)',
    description:
      'Le fournisseur ne livrera pas le reste : la commande passe CLOTUREE avec ' +
      'un motif obligatoire. Ce qui est déjà reçu reste reçu (règle 7) ; plus ' +
      'aucune réception n’est acceptée ensuite.',
  })
  @ApiOkResponse({ type: PurchaseOrderDto })
  @ApiConflictResponse({ type: ErrorResponseDto })
  close(
    @Param('id', CanonicalUuidPipe) id: string,
    @Body() dto: ClosePurchaseOrderDto,
    @CurrentUser() user: AuthenticatedUser,
    @Ip() ip: string,
  ): Promise<PurchaseOrderDto> {
    return this.orders.close(id, dto, { userId: user.id, ipAddress: ip });
  }

  @Roles(RoleCode.ADMIN)
  @RequirePermissions(PERMISSIONS.PURCHASE_CONFIRM)
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
