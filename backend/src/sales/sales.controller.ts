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
  StreamableFile,
} from '@nestjs/common';
import {
  ApiBearerAuth,
  ApiConflictResponse,
  ApiCreatedResponse,
  ApiOkResponse,
  ApiOperation,
  ApiProduces,
  ApiTags,
  ApiUnprocessableEntityResponse,
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
  CreateSaleDto,
  SaleDto,
  SaleExportQueryDto,
  SaleListDto,
  SaleListQueryDto,
} from './dto/sale.dto';
import {
  EXPORT_THROTTLE,
  EXPORT_TYPES,
  exportResponse,
  renderExport,
} from '../common/export/export';
import { SalesService } from './sales.service';
import { SaleReturnsService } from './sale-returns.service';
import { CreateSaleReturnDto, SaleReturnDto } from './dto/sale-return.dto';

@ApiTags('Ventes')
@ApiBearerAuth()
@Controller('sales')
export class SalesController {
  constructor(
    private readonly sales: SalesService,
    private readonly returns: SaleReturnsService,
  ) {}

  @Roles(RoleCode.ADMIN, RoleCode.VENDEUR)
  @RequirePermissions(PERMISSIONS.SALE_CREATE)
  // Remise et crédit se décident sur les droits : relus en base, pas dans le token.
  @Post()
  @ApiOperation({
    summary: 'Valide une vente au comptoir du magasin',
    description:
      'UNE transaction : vente + lignes (prix du tarif figé, TVA figée) + mouvements VENTE + ' +
      'projection + encaissement espèces (caisse ouverte) + crédit éventuel (plafond client). ' +
      'Stock insuffisant → `STOCK_NEGATIVE` ; espèces sans caisse → `CASH_SESSION_REQUIRED` ; ' +
      'prix absent → `PRICE_NOT_DEFINED` ; remise sans droit → `DISCOUNT_NOT_ALLOWED` ; ' +
      'crédit hors plafond → `CREDIT_LIMIT_EXCEEDED`.',
  })
  @ApiCreatedResponse({ type: SaleDto })
  @ApiUnprocessableEntityResponse({ type: ErrorResponseDto })
  create(
    @Body() dto: CreateSaleDto,
    @CurrentUser() user: AuthenticatedUser,
  ): Promise<SaleDto> {
    return this.sales.create(dto, user);
  }

  @Roles(RoleCode.ADMIN, RoleCode.VENDEUR)
  @RequirePermissions(PERMISSIONS.SALE_CREATE)
  @Get()
  @ApiOperation({
    summary: 'Ventes (le vendeur : les siennes ; l’admin : toutes)',
  })
  @ApiOkResponse({ type: SaleListDto })
  findAll(
    @Query() query: SaleListQueryDto,
    @CurrentUser() user: AuthenticatedUser,
  ): Promise<SaleListDto> {
    return this.sales.findAll(query, user);
  }

  /// Export de la liste : MÊMES gardes que `GET /sales`, et les lignes passent
  /// par le même `findAll` — un vendeur n'exporte que SES ventes. Déclarée
  /// AVANT `:id`, sinon « export » serait lu comme un identifiant.
  @Roles(RoleCode.ADMIN, RoleCode.VENDEUR)
  @RequirePermissions(PERMISSIONS.SALE_CREATE)
  // Droits relus EN BASE : plus strict que la liste — un admin rétrogradé
  // n'extrait pas toute la base pendant les 15 min de son jeton.
  @RequireFreshAccess()
  @Throttle(EXPORT_THROTTLE)
  @Get('export')
  @ApiOperation({
    summary: 'Ventes en Excel, CSV ou PDF (mêmes filtres que la liste)',
  })
  @ApiProduces(...EXPORT_TYPES)
  @ApiOkResponse({ schema: { type: 'string', format: 'binary' } })
  async export(
    @Query() query: SaleExportQueryDto,
    @CurrentUser() user: AuthenticatedUser,
  ): Promise<StreamableFile> {
    return exportResponse(
      await renderExport(
        await this.sales.exportDocument(query, user),
        query.format,
      ),
    );
  }

  @Roles(RoleCode.ADMIN, RoleCode.VENDEUR)
  @RequirePermissions(PERMISSIONS.SALE_CREATE)
  @Get(':id')
  @ApiOperation({ summary: 'Détail d’une vente' })
  @ApiOkResponse({ type: SaleDto })
  findOne(
    @Param('id', CanonicalUuidPipe) id: string,
    @CurrentUser() user: AuthenticatedUser,
  ): Promise<SaleDto> {
    return this.sales.findOne(id, user);
  }

  @Roles(RoleCode.ADMIN, RoleCode.VENDEUR)
  @RequirePermissions(PERMISSIONS.SALE_CREATE)
  // Rendu synchrone : bridé à part pour qu'une boucle ne ralentisse pas l'API.
  @Throttle({ default: { ttl: 60_000, limit: 30 } })
  @Get(':id/pdf')
  @ApiOperation({
    summary: 'PDF de la vente : facture A4 si facturée, sinon ticket 80 mm',
    description:
      'Généré serveur à la demande (rendu identique pour tous). Mêmes droits que le détail.',
  })
  @ApiProduces('application/pdf')
  @ApiOkResponse({ schema: { type: 'string', format: 'binary' } })
  async document(
    @Param('id', CanonicalUuidPipe) id: string,
    @CurrentUser() user: AuthenticatedUser,
  ): Promise<StreamableFile> {
    const { filename, pdf } = await this.sales.renderDocument(id, user);
    return new StreamableFile(pdf, {
      type: 'application/pdf',
      disposition: `inline; filename="${filename}"`,
    });
  }

  @Roles(RoleCode.ADMIN, RoleCode.VENDEUR)
  @RequirePermissions(PERMISSIONS.INVOICE_ISSUE)
  @Post(':id/invoice')
  @HttpCode(HttpStatus.OK)
  @ApiOperation({
    summary: 'Convertit un ticket en facture (numéro légal FA-AAAA-NNNNNN)',
    description:
      'Numéro séquentiel SANS TROU attribué serveur, en transaction. Idempotent : ' +
      'une vente déjà facturée garde son numéro.',
  })
  @ApiOkResponse({ type: SaleDto })
  issueInvoice(
    @Param('id', CanonicalUuidPipe) id: string,
    @CurrentUser() user: AuthenticatedUser,
    @Ip() ip: string,
  ): Promise<SaleDto> {
    return this.sales.issueInvoice(id, user, {
      userId: user.id,
      ipAddress: ip,
    });
  }

  @Roles(RoleCode.ADMIN)
  @RequirePermissions(PERMISSIONS.SALE_CANCEL)
  @Post(':id/cancel')
  @HttpCode(HttpStatus.OK)
  @ApiOperation({
    summary: 'Annule une vente validée (admin uniquement)',
    description:
      'Pas de suppression (règle 7) : retours en stock, sortie de caisse, statut ANNULEE. ' +
      'Refus si facturée, réglée ultérieurement, ou caisse déjà clôturée.',
  })
  @ApiOkResponse({ type: SaleDto })
  @ApiConflictResponse({ type: ErrorResponseDto })
  cancel(
    @Param('id', CanonicalUuidPipe) id: string,
    @CurrentUser() user: AuthenticatedUser,
    @Ip() ip: string,
  ): Promise<SaleDto> {
    return this.sales.cancel(id, user, { userId: user.id, ipAddress: ip });
  }

  // ── Retours client et avoirs (P1 bis n°21l) ────────────────────────────────

  /// Retour d'articles d'une vente : ADMIN (`sale.cancel`) — de l'argent sort
  /// ou une dette baisse. Idempotent (`clientMutationId`).
  @Roles(RoleCode.ADMIN)
  @RequirePermissions(PERMISSIONS.SALE_CANCEL)
  @Post(':id/returns')
  @ApiOperation({
    summary: 'Retour client (partiel) : stock, remboursement, avoir',
    description:
      'Espèces : sortie de la caisse ouverte (au plus ce que le client a payé) ; ' +
      'dette : le reste dû baisse. Vente facturée : facture d’avoir AV numérotée.',
  })
  @ApiCreatedResponse({ type: SaleReturnDto })
  createReturn(
    @Param('id', CanonicalUuidPipe) id: string,
    @Body() dto: CreateSaleReturnDto,
    @CurrentUser() user: AuthenticatedUser,
    @Ip() ip: string,
  ): Promise<SaleReturnDto> {
    return this.returns.create(id, dto, user, {
      userId: user.id,
      ipAddress: ip,
    });
  }

  @Roles(RoleCode.ADMIN, RoleCode.VENDEUR)
  @RequirePermissions(PERMISSIONS.SALE_CREATE)
  @Get(':id/returns')
  @ApiOperation({ summary: 'Retours d’une vente (le vendeur : ses ventes)' })
  @ApiOkResponse({ type: [SaleReturnDto] })
  listReturns(
    @Param('id', CanonicalUuidPipe) id: string,
    @CurrentUser() user: AuthenticatedUser,
  ): Promise<SaleReturnDto[]> {
    return this.returns.forSale(id, user);
  }

  @Roles(RoleCode.ADMIN, RoleCode.VENDEUR)
  @RequirePermissions(PERMISSIONS.SALE_CREATE)
  @Throttle({ default: { ttl: 60_000, limit: 30 } })
  @Get('returns/:returnId/pdf')
  @ApiOperation({
    summary: 'Facture d’avoir (vente facturée) ou bon de retour',
  })
  @ApiProduces('application/pdf')
  @ApiOkResponse({ schema: { type: 'string', format: 'binary' } })
  async returnDocument(
    @Param('returnId', CanonicalUuidPipe) returnId: string,
    @CurrentUser() user: AuthenticatedUser,
  ): Promise<StreamableFile> {
    const { filename, pdf } = await this.returns.renderDocument(returnId, user);
    return new StreamableFile(pdf, {
      type: 'application/pdf',
      disposition: `inline; filename="${filename}"`,
    });
  }
}
