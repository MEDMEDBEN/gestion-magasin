import { Body, Controller, Get, Param, ParseUUIDPipe, Post, Query } from '@nestjs/common';
import {
  ApiBearerAuth,
  ApiOkResponse,
  ApiOperation,
  ApiProperty,
  ApiPropertyOptional,
  ApiTags,
} from '@nestjs/swagger';
import { Type } from 'class-transformer';
import {
  ArrayNotEmpty,
  IsArray,
  IsEnum,
  IsNumberString,
  IsOptional,
  IsString,
  IsUUID,
  ValidateNested,
} from 'class-validator';
import { RequirePermissions, RoleCode, Roles } from '../common/auth.decorators';
import { PaginationQueryDto } from '../common/dto/pagination.dto';
import { notImplemented } from '../common/not-implemented';
import { PERMISSIONS } from '../common/permissions';

export enum InventoryTypeDto {
  COMPLET = 'COMPLET',
  TOURNANT = 'TOURNANT',
}

export class CreateInventoryDto {
  @ApiPropertyOptional() @IsUUID() @IsOptional() id?: string;
  @ApiProperty() @IsUUID() locationId!: string;
  @ApiProperty({ enum: InventoryTypeDto, default: InventoryTypeDto.COMPLET })
  @IsEnum(InventoryTypeDto)
  type!: InventoryTypeDto;
  @ApiPropertyOptional({ description: 'Zone comptée pour un inventaire tournant.' })
  @IsString()
  @IsOptional()
  zone?: string;
  @ApiPropertyOptional() @IsUUID() @IsOptional() clientMutationId?: string;
}

export class CountLineDto {
  @ApiProperty() @IsUUID() productId!: string;
  @ApiProperty({ example: '47.500', description: 'Quantité physiquement comptée.' })
  @IsNumberString()
  countedQuantity!: string;
}

export class SubmitCountDto {
  @ApiProperty({ type: [CountLineDto] })
  @IsArray()
  @ArrayNotEmpty()
  @ValidateNested({ each: true })
  @Type(() => CountLineDto)
  lines!: CountLineDto[];
}

export class InventoryDto {
  @ApiProperty() id!: string;
  @ApiProperty() number!: string;
  @ApiProperty({ example: 'EN_COURS', description: 'EN_COURS → TERMINE' }) status!: string;
  @ApiProperty({ enum: InventoryTypeDto }) type!: InventoryTypeDto;
  @ApiProperty({ nullable: true }) validatedAt!: Date | null;
}

export class InventoryLineDto {
  @ApiProperty() productId!: string;
  @ApiProperty({ example: '50.000' }) theoreticalQuantity!: string;
  @ApiProperty({ example: '47.500', nullable: true }) countedQuantity!: string | null;
  @ApiProperty({ example: '-2.500', description: 'compté − théorique' }) difference!: string;
  @ApiProperty({ example: 'ECART', description: 'CONFORME | ECART' }) state!: string;
}

/// CONTRAT FIGÉ — implémentation avec la feature P0 n°9 « Inventaire ».
@ApiTags('Inventaire')
@ApiBearerAuth()
@Controller('inventories')
export class InventoryController {
  @Roles(RoleCode.ADMIN, RoleCode.MAGASINIER)
  @RequirePermissions(PERMISSIONS.INVENTORY_CREATE)
  @Post()
  @ApiOperation({
    summary: 'Lance un inventaire (complet ou tournant)',
    description: 'Fige les quantités théoriques au moment du lancement.',
  })
  @ApiOkResponse({ type: InventoryDto })
  create(@Body() _dto: CreateInventoryDto): Promise<InventoryDto> {
    return notImplemented('Inventaire');
  }

  @Roles(RoleCode.ADMIN, RoleCode.MAGASINIER)
  @RequirePermissions(PERMISSIONS.INVENTORY_CREATE)
  @Get()
  @ApiOperation({ summary: 'Liste paginée des inventaires' })
  @ApiOkResponse({ type: [InventoryDto] })
  findAll(@Query() _query: PaginationQueryDto): Promise<InventoryDto[]> {
    return notImplemented('Inventaire');
  }

  @Roles(RoleCode.ADMIN, RoleCode.MAGASINIER)
  @RequirePermissions(PERMISSIONS.INVENTORY_CREATE)
  @Post(':id/count')
  @ApiOperation({
    summary: 'Saisit le comptage physique',
    description: 'Calcule l’écart par ligne. AUCUN mouvement de stock à cette étape.',
  })
  @ApiOkResponse({ type: [InventoryLineDto] })
  submitCount(
    @Param('id', ParseUUIDPipe) _id: string,
    @Body() _dto: SubmitCountDto,
  ): Promise<InventoryLineDto[]> {
    return notImplemented('Inventaire');
  }

  @Roles(RoleCode.ADMIN)
  @RequirePermissions(PERMISSIONS.INVENTORY_VALIDATE)
  @Post(':id/validate')
  @ApiOperation({
    summary: 'Valide les ajustements (ADMIN SEUL)',
    description:
      'Seule étape qui touche le stock : un mouvement AJUSTEMENT_INVENTAIRE par écart.',
  })
  @ApiOkResponse({ type: InventoryDto })
  validate(@Param('id', ParseUUIDPipe) _id: string): Promise<InventoryDto> {
    return notImplemented('Inventaire');
  }
}
