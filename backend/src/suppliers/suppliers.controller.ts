import {
  Body,
  Controller,
  Get,
  Ip,
  Param,
  Patch,
  Post,
  Query,
} from '@nestjs/common';
import {
  ApiBearerAuth,
  ApiCreatedResponse,
  ApiOkResponse,
  ApiOperation,
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
import { PERMISSIONS } from '../common/permissions';
import {
  CreateSupplierDto,
  CreateSupplierPaymentDto,
  SupplierDto,
  SupplierListDto,
  SupplierListQueryDto,
  SupplierPaymentDto,
  UpdateSupplierDto,
} from './dto/supplier.dto';
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
}
