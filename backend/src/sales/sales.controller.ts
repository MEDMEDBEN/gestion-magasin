import { Body, Controller, Get, Param, ParseUUIDPipe, Post, Query } from '@nestjs/common';
import { ApiBearerAuth, ApiOkResponse, ApiOperation, ApiTags } from '@nestjs/swagger';
import { RequirePermissions, RoleCode, Roles } from '../common/auth.decorators';
import { PaginationQueryDto } from '../common/dto/pagination.dto';
import { notImplemented } from '../common/not-implemented';
import { PERMISSIONS } from '../common/permissions';
import {
  CashSessionDto,
  CloseCashSessionDto,
  CreateCustomerPaymentDto,
  CreateSaleDto,
  SaleDto,
} from './dto/sale.dto';
import { OpenCashSessionDto } from './dto/sale.dto';

/// CONTRAT FIGÉ — implémentation avec la feature P0 n°4 « Ventes ».
@ApiTags('Ventes')
@ApiBearerAuth()
@Controller('sales')
export class SalesController {
  @Roles(RoleCode.ADMIN, RoleCode.VENDEUR)
  @RequirePermissions(PERMISSIONS.SALE_CREATE)
  @Post()
  @ApiOperation({
    summary: 'Valide une vente',
    description:
      'UNE transaction : Sale + SaleLines + StockMovements + projection + dette éventuelle. ' +
      'Une vente qui rendrait le stock négatif est REJETÉE (`STOCK_NEGATIVE`), sauf backorder. ' +
      'Un paiement espèces exige une session de caisse ouverte (`CASH_SESSION_REQUIRED`).',
  })
  @ApiOkResponse({ type: SaleDto })
  create(@Body() _dto: CreateSaleDto): Promise<SaleDto> {
    return notImplemented('Ventes');
  }

  @Roles(RoleCode.ADMIN, RoleCode.VENDEUR)
  @RequirePermissions(PERMISSIONS.SALE_CREATE)
  @Get()
  @ApiOperation({ summary: 'Liste paginée des ventes' })
  @ApiOkResponse({ type: [SaleDto] })
  findAll(@Query() _query: PaginationQueryDto): Promise<SaleDto[]> {
    return notImplemented('Ventes');
  }

  @Roles(RoleCode.ADMIN, RoleCode.VENDEUR)
  @RequirePermissions(PERMISSIONS.INVOICE_ISSUE)
  @Post(':id/invoice')
  @ApiOperation({
    summary: 'Convertit un ticket en facture (numéro légal)',
    description:
      'Numéro séquentiel sans trou attribué SERVEUR, en transaction. ' +
      'Impossible hors-ligne → `INVOICE_ONLINE_ONLY`.',
  })
  @ApiOkResponse({ type: SaleDto })
  issueInvoice(@Param('id', ParseUUIDPipe) _id: string): Promise<SaleDto> {
    return notImplemented('Ventes / facturation');
  }

  @Roles(RoleCode.ADMIN)
  @RequirePermissions(PERMISSIONS.SALE_CANCEL)
  @Post(':id/cancel')
  @ApiOperation({
    summary: 'Annule une vente validée (admin uniquement)',
    description:
      'Pas de suppression physique : mouvements inverses + statut ANNULEE (règle 7).',
  })
  @ApiOkResponse({ type: SaleDto })
  cancel(@Param('id', ParseUUIDPipe) _id: string): Promise<SaleDto> {
    return notImplemented('Ventes');
  }
}

@ApiTags('Caisse')
@ApiBearerAuth()
@Controller('cash-sessions')
export class CashSessionsController {
  @Roles(RoleCode.ADMIN, RoleCode.VENDEUR)
  @RequirePermissions(PERMISSIONS.CASH_SESSION_MANAGE)
  @Post()
  @ApiOperation({ summary: 'Ouvre une session de caisse avec un fond' })
  @ApiOkResponse({ type: CashSessionDto })
  open(@Body() _dto: OpenCashSessionDto): Promise<CashSessionDto> {
    return notImplemented('Ventes / caisse');
  }

  @Roles(RoleCode.ADMIN, RoleCode.VENDEUR)
  @RequirePermissions(PERMISSIONS.CASH_SESSION_MANAGE)
  @Post(':id/close')
  @ApiOperation({
    summary: 'Clôture la session et produit le rapport Z',
    description: 'Compare le réel au théorique et enregistre l’écart.',
  })
  @ApiOkResponse({ type: CashSessionDto })
  close(
    @Param('id', ParseUUIDPipe) _id: string,
    @Body() _dto: CloseCashSessionDto,
  ): Promise<CashSessionDto> {
    return notImplemented('Ventes / caisse');
  }

  @Roles(RoleCode.ADMIN, RoleCode.VENDEUR)
  @RequirePermissions(PERMISSIONS.CASH_REPORT_READ)
  @Get(':id/report')
  @ApiOperation({ summary: 'Rapport Z d’une session' })
  @ApiOkResponse({ type: CashSessionDto })
  report(@Param('id', ParseUUIDPipe) _id: string): Promise<CashSessionDto> {
    return notImplemented('Ventes / caisse');
  }
}

@ApiTags('Paiements')
@ApiBearerAuth()
@Controller('payments')
export class PaymentsController {
  @Roles(RoleCode.ADMIN, RoleCode.VENDEUR)
  @RequirePermissions(PERMISSIONS.CUSTOMER_PAYMENT_CREATE)
  @Post('customer')
  @ApiOperation({
    summary: 'Enregistre un paiement client',
    description: 'Réduit la dette, qui reste TOUJOURS recalculée (jamais stockée).',
  })
  createCustomerPayment(@Body() _dto: CreateCustomerPaymentDto): Promise<unknown> {
    return notImplemented('Clients / dettes');
  }

  @Roles(RoleCode.ADMIN)
  @RequirePermissions(PERMISSIONS.SUPPLIER_PAYMENT_CREATE)
  @Post('supplier')
  @ApiOperation({ summary: 'Enregistre un paiement fournisseur (admin uniquement)' })
  createSupplierPayment(@Body() _dto: Record<string, never>): Promise<unknown> {
    return notImplemented('Fournisseurs / dettes');
  }
}
