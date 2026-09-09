import { Body, Controller, Get, Param, ParseUUIDPipe, Post, Query } from '@nestjs/common';
import {
  ApiBearerAuth,
  ApiOkResponse,
  ApiOperation,
  ApiProperty,
  ApiPropertyOptional,
  ApiTags,
} from '@nestjs/swagger';
import { IsInt, IsOptional, IsString, IsUUID, Min, MinLength } from 'class-validator';
import { RequirePermissions, RoleCode, Roles } from '../common/auth.decorators';
import { PaginationQueryDto } from '../common/dto/pagination.dto';
import { notImplemented } from '../common/not-implemented';
import { PERMISSIONS } from '../common/permissions';

const ALL_ROLES = [RoleCode.ADMIN, RoleCode.VENDEUR, RoleCode.MAGASINIER];

export class CreateCustomerDto {
  @ApiPropertyOptional() @IsUUID() @IsOptional() id?: string;
  @ApiProperty() @IsString() @MinLength(2) name!: string;
  @ApiPropertyOptional() @IsString() @IsOptional() phone?: string;
  @ApiPropertyOptional() @IsString() @IsOptional() email?: string;
  @ApiPropertyOptional() @IsString() @IsOptional() address?: string;
  @ApiPropertyOptional({ description: 'Tarif par défaut appliqué à ses ventes.' })
  @IsUUID()
  @IsOptional()
  priceTierId?: string;
  @ApiPropertyOptional({
    default: 0,
    description:
      'Plafond de crédit en centimes, fixé par l’ADMIN. 0 = aucune vente à crédit.',
  })
  @IsInt()
  @Min(0)
  @IsOptional()
  creditLimit?: number;
}

export class CustomerDto {
  @ApiProperty() id!: string;
  @ApiProperty() name!: string;
  @ApiProperty({ nullable: true }) phone!: string | null;
  @ApiProperty({ nullable: true }) priceTierId!: string | null;
  @ApiProperty() creditLimit!: number;
  @ApiProperty({ description: 'Dette restante, TOUJOURS recalculée.' }) balanceDue!: number;
  @ApiProperty() isActive!: boolean;
}

export class CreateSupplierDto {
  @ApiPropertyOptional() @IsUUID() @IsOptional() id?: string;
  @ApiProperty() @IsString() @MinLength(2) name!: string;
  @ApiPropertyOptional() @IsString() @IsOptional() phone?: string;
  @ApiPropertyOptional() @IsString() @IsOptional() email?: string;
  @ApiPropertyOptional() @IsString() @IsOptional() address?: string;
  @ApiPropertyOptional() @IsString() @IsOptional() contactName?: string;
}

export class SupplierDto {
  @ApiProperty() id!: string;
  @ApiProperty() name!: string;
  @ApiProperty({ nullable: true }) phone!: string | null;
  @ApiProperty({ description: 'Reste dû, TOUJOURS recalculé.' }) balanceDue!: number;
  @ApiProperty() isActive!: boolean;
}

/// CONTRAT FIGÉ — implémentation avec la feature P0 n°5.
@ApiTags('Clients')
@ApiBearerAuth()
@Controller('customers')
export class CustomersController {
  @Roles(...ALL_ROLES)
  @RequirePermissions(PERMISSIONS.CUSTOMER_READ)
  @Get()
  @ApiOperation({ summary: 'Liste paginée des clients' })
  @ApiOkResponse({ type: [CustomerDto] })
  findAll(@Query() _query: PaginationQueryDto): Promise<CustomerDto[]> {
    return notImplemented('Clients');
  }

  @Roles(...ALL_ROLES)
  @RequirePermissions(PERMISSIONS.CUSTOMER_READ)
  @Get(':id')
  @ApiOperation({ summary: 'Fiche client : dette, échéances, historique' })
  @ApiOkResponse({ type: CustomerDto })
  findOne(@Param('id', ParseUUIDPipe) _id: string): Promise<CustomerDto> {
    return notImplemented('Clients');
  }

  @Roles(RoleCode.ADMIN, RoleCode.VENDEUR)
  @RequirePermissions(PERMISSIONS.CUSTOMER_WRITE)
  @Post()
  @ApiOperation({
    summary: 'Crée un client',
    description: 'Le plafond de crédit reste modifiable par l’ADMIN uniquement.',
  })
  @ApiOkResponse({ type: CustomerDto })
  create(@Body() _dto: CreateCustomerDto): Promise<CustomerDto> {
    return notImplemented('Clients');
  }
}

@ApiTags('Fournisseurs')
@ApiBearerAuth()
@Controller('suppliers')
export class SuppliersController {
  @Roles(...ALL_ROLES)
  @RequirePermissions(PERMISSIONS.SUPPLIER_READ)
  @Get()
  @ApiOperation({ summary: 'Liste paginée des fournisseurs' })
  @ApiOkResponse({ type: [SupplierDto] })
  findAll(@Query() _query: PaginationQueryDto): Promise<SupplierDto[]> {
    return notImplemented('Fournisseurs');
  }

  @Roles(RoleCode.ADMIN)
  @RequirePermissions(PERMISSIONS.SUPPLIER_WRITE)
  @Post()
  @ApiOperation({ summary: 'Crée un fournisseur (admin uniquement)' })
  @ApiOkResponse({ type: SupplierDto })
  create(@Body() _dto: CreateSupplierDto): Promise<SupplierDto> {
    return notImplemented('Fournisseurs');
  }
}
