import {
  Body,
  Controller,
  Get,
  Ip,
  Param,
  Patch,
  Post,
  Query,
  StreamableFile,
} from '@nestjs/common';
import {
  ApiBearerAuth,
  ApiCreatedResponse,
  ApiOkResponse,
  ApiOperation,
  ApiTags,
  ApiUnprocessableEntityResponse,
  ApiProduces,
} from '@nestjs/swagger';
import { Throttle } from '@nestjs/throttler';
import {
  AuthenticatedUser,
  CurrentUser,
  RequirePermissions,
  RoleCode,
  Roles,
} from '../common/auth.decorators';
import { CanonicalUuidPipe } from '../common/canonical-uuid.pipe';
import { ErrorResponseDto } from '../common/dto/error-response.dto';
import {
  PaymentHistoryDto,
  ReversePaymentDto,
} from '../common/dto/payment.dto';
import { PaginationQueryDto } from '../common/dto/pagination.dto';
import { PERMISSIONS } from '../common/permissions';
import {
  CreateSupplierDto,
  CreateSupplierPaymentDto,
  SupplierDto,
  SupplierExportQueryDto,
  SupplierListDto,
  SupplierListQueryDto,
  SupplierPaymentDto,
  UpdateSupplierDto,
} from './dto/supplier.dto';
import {
  EXPORT_THROTTLE,
  EXPORT_TYPES,
  exportResponse,
  renderExport,
} from '../common/export/export';
import { SuppliersService } from './suppliers.service';

@ApiTags('Fournisseurs')
@ApiBearerAuth()
@Controller('suppliers')
export class SuppliersController {
  constructor(private readonly suppliers: SuppliersService) {}

  // Le VENDEUR n'a AUCUN accès aux fournisseurs (docs/permissions.md).
  @Roles(RoleCode.ADMIN, RoleCode.MAGASINIER)
  @RequirePermissions(PERMISSIONS.SUPPLIER_READ)
  @Get()
  @ApiOperation({
    summary: 'Fournisseurs (recherche nom, téléphone, code) avec leur dette',
  })
  @ApiOkResponse({ type: SupplierListDto })
  findAll(@Query() query: SupplierListQueryDto): Promise<SupplierListDto> {
    return this.suppliers.findAll(query);
  }

  /// Export : MÊMES gardes que `GET /suppliers` (jamais le vendeur).
  /// Déclarée AVANT `:id`, sinon « export » serait lu comme un identifiant.
  @Roles(RoleCode.ADMIN, RoleCode.MAGASINIER)
  @RequirePermissions(PERMISSIONS.SUPPLIER_READ)
  @Throttle(EXPORT_THROTTLE)
  @Get('export')
  @ApiOperation({
    summary: 'Fournisseurs (ou dettes fournisseurs) en Excel, CSV ou PDF',
  })
  @ApiProduces(...EXPORT_TYPES)
  @ApiOkResponse({ schema: { type: 'string', format: 'binary' } })
  async export(
    @Query() query: SupplierExportQueryDto,
  ): Promise<StreamableFile> {
    return exportResponse(
      await renderExport(
        await this.suppliers.exportDocument(query),
        query.format,
      ),
    );
  }

  @Roles(RoleCode.ADMIN, RoleCode.MAGASINIER)
  @RequirePermissions(PERMISSIONS.SUPPLIER_READ)
  @Get(':id/payments')
  @ApiOperation({
    summary:
      'Historique des paiements d’un fournisseur (contre-passations comprises)',
  })
  @ApiOkResponse({ type: PaymentHistoryDto })
  payments(
    @Param('id', CanonicalUuidPipe) id: string,
    @Query() query: PaginationQueryDto,
  ): Promise<PaymentHistoryDto> {
    return this.suppliers.payments(id, query);
  }

  @Roles(RoleCode.ADMIN, RoleCode.MAGASINIER)
  @RequirePermissions(PERMISSIONS.SUPPLIER_READ)
  @Get(':id')
  @ApiOperation({ summary: 'Fiche fournisseur' })
  @ApiOkResponse({ type: SupplierDto })
  findOne(@Param('id', CanonicalUuidPipe) id: string): Promise<SupplierDto> {
    return this.suppliers.findOne(id);
  }

  @Roles(RoleCode.ADMIN)
  @RequirePermissions(PERMISSIONS.SUPPLIER_WRITE)
  @Post()
  @ApiOperation({
    summary: 'Crée un fournisseur (admin uniquement)',
    description:
      '`openingBalance` = dette déjà due avant le logiciel (reprise de l’existant).',
  })
  @ApiCreatedResponse({ type: SupplierDto })
  create(
    @Body() dto: CreateSupplierDto,
    @CurrentUser() user: AuthenticatedUser,
    @Ip() ip: string,
  ): Promise<SupplierDto> {
    return this.suppliers.create(dto, { userId: user.id, ipAddress: ip });
  }

  @Roles(RoleCode.ADMIN)
  @RequirePermissions(PERMISSIONS.SUPPLIER_WRITE)
  @Patch(':id')
  @ApiOperation({ summary: 'Modifie un fournisseur (admin uniquement)' })
  @ApiOkResponse({ type: SupplierDto })
  update(
    @Param('id', CanonicalUuidPipe) id: string,
    @Body() dto: UpdateSupplierDto,
    @CurrentUser() user: AuthenticatedUser,
    @Ip() ip: string,
  ): Promise<SupplierDto> {
    return this.suppliers.update(id, dto, { userId: user.id, ipAddress: ip });
  }
}

@ApiTags('Paiements')
@ApiBearerAuth()
@Controller('payments')
export class SupplierPaymentsController {
  constructor(private readonly suppliers: SuppliersService) {}

  @Roles(RoleCode.ADMIN)
  @RequirePermissions(PERMISSIONS.SUPPLIER_PAYMENT_CREATE)
  @Post('supplier')
  @ApiOperation({
    summary: 'Enregistre un paiement fournisseur (admin uniquement)',
    description:
      'Jamais au-delà du reste dû. `fromCash` : sortie de la caisse OUVERTE ' +
      '(`CASH_SESSION_REQUIRED` sans caisse) ; sinon la caisse n’est pas touchée. ' +
      'Renvoyer le même `id` rend le paiement déjà enregistré.',
  })
  @ApiCreatedResponse({ type: SupplierPaymentDto })
  @ApiUnprocessableEntityResponse({ type: ErrorResponseDto })
  pay(
    @Body() dto: CreateSupplierPaymentDto,
    @CurrentUser() user: AuthenticatedUser,
    @Ip() ip: string,
  ): Promise<SupplierPaymentDto> {
    return this.suppliers.pay(dto, user, { userId: user.id, ipAddress: ip });
  }

  @Roles(RoleCode.ADMIN)
  @RequirePermissions(PERMISSIONS.SUPPLIER_PAYMENT_CREATE)
  @Post('supplier/:id/reverse')
  @ApiOperation({
    summary:
      'Contre-passe un paiement fournisseur (ADMIN) — jamais de suppression',
    description:
      'Écriture opposée : la dette revient. Paiement sorti de la caisse → espèces ' +
      'remises dans la caisse ouverte de l’admin ; hors caisse → caisse non touchée.',
  })
  @ApiCreatedResponse({ type: SupplierPaymentDto })
  reverse(
    @Param('id', CanonicalUuidPipe) id: string,
    @Body() dto: ReversePaymentDto,
    @CurrentUser() user: AuthenticatedUser,
    @Ip() ip: string,
  ): Promise<SupplierPaymentDto> {
    return this.suppliers.reverse(id, dto, user, {
      userId: user.id,
      ipAddress: ip,
    });
  }
}
