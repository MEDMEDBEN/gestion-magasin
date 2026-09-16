import { Body, Controller, Get, Post, Query } from '@nestjs/common';
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
  IsUUID,
  Min,
  ValidateNested,
} from 'class-validator';
import { RequirePermissions, RoleCode, Roles } from '../common/auth.decorators';
import { PaginationQueryDto } from '../common/dto/pagination.dto';
import { notImplemented } from '../common/not-implemented';
import { PERMISSIONS } from '../common/permissions';

export class CreateReceptionLineDto {
  @ApiProperty() @IsUUID() productId!: string;
  @ApiPropertyOptional({
    description: 'Ligne de commande couverte, si rattachée.',
  })
  @IsUUID()
  @IsOptional()
  purchaseLineId?: string;
  @ApiProperty({ example: '70.000', description: 'Quantité RÉELLEMENT reçue.' })
  @IsNumberString()
  receivedQuantity!: string;
  @ApiProperty({
    example: 120000,
    description: 'Alimente `Product.lastPurchasePriceHt`.',
  })
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
