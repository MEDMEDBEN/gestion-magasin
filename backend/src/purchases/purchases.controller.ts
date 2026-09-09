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
  IsInt,
  IsNumberString,
  IsOptional,
  IsString,
  IsUUID,
  Min,
  ValidateNested,
} from 'class-validator';
import { RequirePermissions, RoleCode, Roles } from '../common/auth.decorators';
import { PaginationQueryDto } from '../common/dto/pagination.dto';
import { notImplemented } from '../common/not-implemented';
import { PERMISSIONS } from '../common/permissions';

export class CreatePurchaseLineDto {
  @ApiProperty() @IsUUID() productId!: string;
  @ApiProperty({ example: '100.000' }) @IsNumberString() orderedQuantity!: string;
  @ApiProperty({ example: 120000, description: 'Prix d’achat HT en centimes.' })
  @IsInt()
  @Min(0)
  unitPriceHt!: number;
}

export class CreatePurchaseOrderDto {
  @ApiPropertyOptional() @IsUUID() @IsOptional() id?: string;
  @ApiProperty() @IsUUID() supplierId!: string;
  @ApiPropertyOptional({ description: 'Date de livraison attendue (ISO 8601).' })
  @IsString()
  @IsOptional()
  expectedDate?: string;
  @ApiProperty({ type: [CreatePurchaseLineDto] })
  @IsArray()
  @ArrayNotEmpty()
  @ValidateNested({ each: true })
  @Type(() => CreatePurchaseLineDto)
  lines!: CreatePurchaseLineDto[];
}

export class PurchaseOrderDto {
  @ApiProperty() id!: string;
  @ApiProperty() number!: string;
  @ApiProperty() supplierId!: string;
  @ApiProperty({
    example: 'BROUILLON',
    description: 'BROUILLON → COMMANDEE → CONFIRMEE → PARTIELLEMENT_RECUE → RECUE (+ ANNULEE)',
  })
  status!: string;
  @ApiProperty() totalHt!: number;
  @ApiProperty() totalTtc!: number;
}

export class CreateReceptionLineDto {
  @ApiProperty() @IsUUID() productId!: string;
  @ApiPropertyOptional({ description: 'Ligne de commande couverte, si rattachée.' })
  @IsUUID()
  @IsOptional()
  purchaseLineId?: string;
  @ApiProperty({ example: '70.000', description: 'Quantité RÉELLEMENT reçue.' })
  @IsNumberString()
  receivedQuantity!: string;
  @ApiProperty({ example: 120000, description: 'Alimente `Product.lastPurchasePriceHt`.' })
  @IsInt()
  @Min(0)
  unitPriceHt!: number;
}

export class CreateReceptionDto {
  @ApiPropertyOptional() @IsUUID() @IsOptional() id?: string;
  @ApiPropertyOptional({ description: 'Absent = réception hors commande.' })
  @IsUUID()
  @IsOptional()
  purchaseOrderId?: string;
  @ApiProperty() @IsUUID() supplierId!: string;
  @ApiProperty() @IsUUID() locationId!: string;
  @ApiProperty({ type: [CreateReceptionLineDto] })
  @IsArray()
  @ArrayNotEmpty()
  @ValidateNested({ each: true })
  @Type(() => CreateReceptionLineDto)
  lines!: CreateReceptionLineDto[];
  @ApiPropertyOptional() @IsUUID() @IsOptional() clientMutationId?: string;
}

export class ReceptionDto {
  @ApiProperty() id!: string;
  @ApiProperty() number!: string;
  @ApiProperty({ nullable: true }) purchaseOrderId!: string | null;
  @ApiProperty() receivedAt!: Date;
}

/// CONTRAT FIGÉ — implémentation avec la feature P0 n°6 « Achats ».
@ApiTags('Achats')
@ApiBearerAuth()
@Controller('purchase-orders')
export class PurchaseOrdersController {
  @Roles(RoleCode.ADMIN, RoleCode.MAGASINIER)
  @RequirePermissions(PERMISSIONS.PURCHASE_CREATE)
  @Post()
  @ApiOperation({ summary: 'Crée une commande fournisseur (admin ou magasinier)' })
  @ApiOkResponse({ type: PurchaseOrderDto })
  create(@Body() _dto: CreatePurchaseOrderDto): Promise<PurchaseOrderDto> {
    return notImplemented('Achats');
  }

  @Roles(RoleCode.ADMIN, RoleCode.MAGASINIER)
  @RequirePermissions(PERMISSIONS.PURCHASE_CREATE)
  @Get()
  @ApiOperation({ summary: 'Liste paginée des commandes' })
  @ApiOkResponse({ type: [PurchaseOrderDto] })
  findAll(@Query() _query: PaginationQueryDto): Promise<PurchaseOrderDto[]> {
    return notImplemented('Achats');
  }

  @Roles(RoleCode.ADMIN)
  @RequirePermissions(PERMISSIONS.PURCHASE_CONFIRM)
  @Post(':id/confirm')
  @ApiOperation({ summary: 'Confirme une commande (ADMIN SEUL)' })
  @ApiOkResponse({ type: PurchaseOrderDto })
  confirm(@Param('id', ParseUUIDPipe) _id: string): Promise<PurchaseOrderDto> {
    return notImplemented('Achats');
  }

  @Roles(RoleCode.ADMIN)
  @RequirePermissions(PERMISSIONS.PURCHASE_CONFIRM)
  @Post(':id/cancel')
  @ApiOperation({ summary: 'Annule une commande (ADMIN SEUL)' })
  @ApiOkResponse({ type: PurchaseOrderDto })
  cancel(@Param('id', ParseUUIDPipe) _id: string): Promise<PurchaseOrderDto> {
    return notImplemented('Achats');
  }
}

/// CONTRAT FIGÉ — implémentation avec la feature P0 n°7 « Réceptions ».
@ApiTags('Réceptions')
@ApiBearerAuth()
@Controller('receptions')
export class ReceptionsController {
  @Roles(RoleCode.ADMIN, RoleCode.MAGASINIER)
  @RequirePermissions(PERMISSIONS.RECEPTION_CREATE)
  @Post()
  @ApiOperation({
    summary: 'Enregistre une réception (partielle possible)',
    description:
      'Le stock augmente UNIQUEMENT des quantités réellement reçues. ' +
      'Une commande peut avoir plusieurs réceptions ; le statut suit le cumul.',
  })
  @ApiOkResponse({ type: ReceptionDto })
  create(@Body() _dto: CreateReceptionDto): Promise<ReceptionDto> {
    return notImplemented('Réceptions');
  }

  @Roles(RoleCode.ADMIN, RoleCode.MAGASINIER)
  @RequirePermissions(PERMISSIONS.RECEPTION_CREATE)
  @Get()
  @ApiOperation({ summary: 'Liste paginée des réceptions' })
  @ApiOkResponse({ type: [ReceptionDto] })
  findAll(@Query() _query: PaginationQueryDto): Promise<ReceptionDto[]> {
    return notImplemented('Réceptions');
  }
}
