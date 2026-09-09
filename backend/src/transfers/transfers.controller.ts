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

export enum PriorityDto {
  BASSE = 'BASSE',
  NORMALE = 'NORMALE',
  HAUTE = 'HAUTE',
  URGENTE = 'URGENTE',
}

export class TransferLineInputDto {
  @ApiProperty() @IsUUID() productId!: string;
  @ApiProperty({ example: '20.000' }) @IsNumberString() quantity!: string;
}

export class CreateTransferDto {
  @ApiPropertyOptional() @IsUUID() @IsOptional() id?: string;
  @ApiProperty({ description: 'Origine — le DEPOT en pratique.' })
  @IsUUID()
  fromLocationId!: string;
  @ApiProperty({ description: 'Destination — le MAGASIN en pratique.' })
  @IsUUID()
  toLocationId!: string;
  @ApiPropertyOptional({ enum: PriorityDto, default: PriorityDto.NORMALE })
  @IsEnum(PriorityDto)
  @IsOptional()
  priority?: PriorityDto;
  @ApiPropertyOptional() @IsString() @IsOptional() comment?: string;
  @ApiProperty({ type: [TransferLineInputDto] })
  @IsArray()
  @ArrayNotEmpty()
  @ValidateNested({ each: true })
  @Type(() => TransferLineInputDto)
  lines!: TransferLineInputDto[];
  @ApiPropertyOptional() @IsUUID() @IsOptional() clientMutationId?: string;
}

export class PrepareTransferLineDto {
  @ApiProperty() @IsUUID() productId!: string;
  @ApiProperty({
    example: '18.000',
    description: 'Préparation PARTIELLE autorisée : quantité réellement préparée.',
  })
  @IsNumberString()
  preparedQuantity!: string;
}

export class PrepareTransferDto {
  @ApiProperty({ type: [PrepareTransferLineDto] })
  @IsArray()
  @ArrayNotEmpty()
  @ValidateNested({ each: true })
  @Type(() => PrepareTransferLineDto)
  lines!: PrepareTransferLineDto[];
}

export class TransferDto {
  @ApiProperty() id!: string;
  @ApiProperty() number!: string;
  @ApiProperty({
    example: 'DEMANDEE',
    description:
      'DEMANDEE → ACCEPTEE → EN_PREPARATION → PREPAREE → EN_TRANSIT → RECUE (+ REFUSEE, ANNULEE)',
  })
  status!: string;
  @ApiProperty({ enum: PriorityDto }) priority!: PriorityDto;
  @ApiProperty() requestedAt!: Date;
}

/// CONTRAT FIGÉ — implémentation avec la feature P0 n°8 « Transferts ».
@ApiTags('Transferts')
@ApiBearerAuth()
@Controller('transfers')
export class TransfersController {
  @Roles(RoleCode.ADMIN, RoleCode.VENDEUR)
  @RequirePermissions(PERMISSIONS.TRANSFER_REQUEST)
  @Post()
  @ApiOperation({
    summary: 'Crée une demande magasin → dépôt',
    description: 'Une demande est un vrai transfert suivi, jamais un simple message.',
  })
  @ApiOkResponse({ type: TransferDto })
  request(@Body() _dto: CreateTransferDto): Promise<TransferDto> {
    return notImplemented('Transferts');
  }

  @Roles(RoleCode.ADMIN, RoleCode.VENDEUR, RoleCode.MAGASINIER)
  @RequirePermissions(PERMISSIONS.TRANSFER_REQUEST)
  @Get()
  @ApiOperation({ summary: 'Liste paginée des transferts' })
  @ApiOkResponse({ type: [TransferDto] })
  findAll(@Query() _query: PaginationQueryDto): Promise<TransferDto[]> {
    return notImplemented('Transferts');
  }

  @Roles(RoleCode.ADMIN, RoleCode.MAGASINIER)
  @RequirePermissions(PERMISSIONS.TRANSFER_PREPARE)
  @Post(':id/prepare')
  @ApiOperation({ summary: 'Prépare la demande (préparation partielle autorisée)' })
  @ApiOkResponse({ type: TransferDto })
  prepare(
    @Param('id', ParseUUIDPipe) _id: string,
    @Body() _dto: PrepareTransferDto,
  ): Promise<TransferDto> {
    return notImplemented('Transferts');
  }

  @Roles(RoleCode.ADMIN, RoleCode.MAGASINIER)
  @RequirePermissions(PERMISSIONS.TRANSFER_PREPARE)
  @Post(':id/ship')
  @ApiOperation({
    summary: 'Expédie le transfert',
    description: 'Sort le stock du dépôt vers TRANSIT (mouvement TRANSFERT_SORTIE).',
  })
  @ApiOkResponse({ type: TransferDto })
  ship(@Param('id', ParseUUIDPipe) _id: string): Promise<TransferDto> {
    return notImplemented('Transferts');
  }

  @Roles(RoleCode.ADMIN, RoleCode.VENDEUR)
  @RequirePermissions(PERMISSIONS.TRANSFER_RECEIVE)
  @Post(':id/receive')
  @ApiOperation({
    summary: 'Réceptionne au magasin',
    description:
      'TRANSIT → MAGASIN (mouvement TRANSFERT_ENTREE). Le produit n’est vendable qu’après.',
  })
  @ApiOkResponse({ type: TransferDto })
  receive(@Param('id', ParseUUIDPipe) _id: string): Promise<TransferDto> {
    return notImplemented('Transferts');
  }

  @Roles(RoleCode.ADMIN, RoleCode.VENDEUR, RoleCode.MAGASINIER)
  @RequirePermissions(PERMISSIONS.TRANSFER_CANCEL)
  @Post(':id/cancel')
  @ApiOperation({ summary: 'Refuse ou annule un transfert' })
  @ApiOkResponse({ type: TransferDto })
  cancel(@Param('id', ParseUUIDPipe) _id: string): Promise<TransferDto> {
    return notImplemented('Transferts');
  }
}
