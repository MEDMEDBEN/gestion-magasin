import { Body, Controller, Get, Post } from '@nestjs/common';
import {
  ApiBearerAuth,
  ApiOkResponse,
  ApiOperation,
  ApiProperty,
  ApiPropertyOptional,
  ApiTags,
} from '@nestjs/swagger';
import { IsEnum, IsOptional, IsString, IsUUID, MinLength } from 'class-validator';
import { RequirePermissions, RoleCode, Roles } from '../common/auth.decorators';
import { notImplemented } from '../common/not-implemented';
import { PERMISSIONS } from '../common/permissions';

const ALL_ROLES = [RoleCode.ADMIN, RoleCode.VENDEUR, RoleCode.MAGASINIER];

/// Aligné sur l'enum `LocationType` du schéma Prisma.
export enum LocationTypeDto {
  MAGASIN = 'MAGASIN',
  DEPOT = 'DEPOT',
  TRANSIT = 'TRANSIT',
  EMPLACEMENT = 'EMPLACEMENT',
}

export class CreateLocationDto {
  @ApiProperty({ example: 'DEP-A-02-04-03' }) @IsString() @MinLength(1) code!: string;
  @ApiProperty({ example: 'Zone A · Rayon 02 · Étagère 04 · Position 03' })
  @IsString()
  @MinLength(2)
  name!: string;
  @ApiProperty({ enum: LocationTypeDto }) @IsEnum(LocationTypeDto) type!: LocationTypeDto;
  @ApiPropertyOptional({ description: 'DEPOT parent pour un EMPLACEMENT' })
  @IsUUID()
  @IsOptional()
  parentId?: string;
  @ApiPropertyOptional() @IsString() @IsOptional() zone?: string;
  @ApiPropertyOptional() @IsString() @IsOptional() aisle?: string;
  @ApiPropertyOptional() @IsString() @IsOptional() shelf?: string;
  @ApiPropertyOptional() @IsString() @IsOptional() position?: string;
}

export class LocationDto {
  @ApiProperty() id!: string;
  @ApiProperty() code!: string;
  @ApiProperty() name!: string;
  @ApiProperty({ enum: LocationTypeDto }) type!: LocationTypeDto;
  @ApiProperty({ nullable: true }) parentId!: string | null;
  @ApiProperty() isActive!: boolean;
}

/// CONTRAT FIGÉ — implémentation avec la feature P0 n°2.
@ApiTags('Emplacements')
@ApiBearerAuth()
@Controller('locations')
export class LocationsController {
  @Roles(...ALL_ROLES)
  @RequirePermissions(PERMISSIONS.PRODUCT_READ)
  @Get()
  @ApiOperation({
    summary: 'Liste des emplacements',
    description:
      'MAGASIN / DEPOT / TRANSIT portent le stock ; EMPLACEMENT = position physique au dépôt.',
  })
  @ApiOkResponse({ type: [LocationDto] })
  findAll(): Promise<LocationDto[]> {
    return notImplemented('Produits / emplacements');
  }

  @Roles(RoleCode.ADMIN, RoleCode.MAGASINIER)
  @RequirePermissions(PERMISSIONS.LOCATION_MANAGE)
  @Post()
  @ApiOperation({ summary: 'Crée un emplacement de dépôt' })
  @ApiOkResponse({ type: LocationDto })
  create(@Body() _dto: CreateLocationDto): Promise<LocationDto> {
    return notImplemented('Produits / emplacements');
  }
}
