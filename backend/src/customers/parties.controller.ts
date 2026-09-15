import { Body, Controller, Get, Post, Query } from '@nestjs/common';
import {
  ApiBearerAuth,
  ApiOkResponse,
  ApiOperation,
  ApiProperty,
  ApiPropertyOptional,
  ApiTags,
} from '@nestjs/swagger';
import { IsOptional, IsString, IsUUID, MinLength } from 'class-validator';
import { RequirePermissions, RoleCode, Roles } from '../common/auth.decorators';
import { PaginationQueryDto } from '../common/dto/pagination.dto';
import { notImplemented } from '../common/not-implemented';
import { PERMISSIONS } from '../common/permissions';

const ALL_ROLES = [RoleCode.ADMIN, RoleCode.VENDEUR, RoleCode.MAGASINIER];

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
  @ApiProperty({ description: 'Reste dû, TOUJOURS recalculé.' })
  balanceDue!: number;
  @ApiProperty() isActive!: boolean;
}

/// CONTRAT FIGÉ — implémentation avec la feature P0 n°5.
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
