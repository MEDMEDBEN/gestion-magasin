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
  UseGuards,
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
import { notImplemented } from '../common/not-implemented';
import { PERMISSIONS } from '../common/permissions';
import {
  CreateSaleDto,
  SaleDto,
  SaleListDto,
  SaleListQueryDto,
} from './dto/sale.dto';
import { SalesService } from './sales.service';

@ApiTags('Ventes')
@ApiBearerAuth()
@Controller('sales')
export class SalesController {
  constructor(private readonly sales: SalesService) {}

  @Roles(RoleCode.ADMIN, RoleCode.VENDEUR)
  @RequirePermissions(PERMISSIONS.SALE_CREATE)
  // Remise et crédit se décident sur les droits : relus en base, pas dans le token.
  @UseGuards(FreshAccessGuard)
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
  @UseGuards(FreshAccessGuard)
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
  @UseGuards(FreshAccessGuard)
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
}

@ApiTags('Paiements')
@ApiBearerAuth()
@Controller('payments')
export class SupplierPaymentsController {
  @Roles(RoleCode.ADMIN)
  @RequirePermissions(PERMISSIONS.SUPPLIER_PAYMENT_CREATE)
  @Post('supplier')
  @ApiOperation({
    summary: 'Enregistre un paiement fournisseur (admin uniquement)',
  })
  createSupplierPayment(@Body() _dto: Record<string, never>): Promise<unknown> {
    return notImplemented('Fournisseurs / dettes');
  }
}
