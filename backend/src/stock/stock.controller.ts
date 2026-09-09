import { Body, Controller, Get, Post, Query } from '@nestjs/common';
import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import { ApiBearerAuth, ApiOkResponse, ApiOperation, ApiTags } from '@nestjs/swagger';
import {
  IsEnum,
  IsNumberString,
  IsOptional,
  IsString,
  IsUUID,
} from 'class-validator';
import { RequirePermissions, RoleCode, Roles } from '../common/auth.decorators';
import { PaginationQueryDto } from '../common/dto/pagination.dto';
import { notImplemented } from '../common/not-implemented';
import { PERMISSIONS } from '../common/permissions';

const ALL_ROLES = [RoleCode.ADMIN, RoleCode.VENDEUR, RoleCode.MAGASINIER];

/// Aligné sur l'enum `StockMovementType` du schéma Prisma.
export enum StockMovementTypeDto {
  RECEPTION = 'RECEPTION',
  VENTE = 'VENTE',
  RETOUR_CLIENT = 'RETOUR_CLIENT',
  RETOUR_FOURNISSEUR = 'RETOUR_FOURNISSEUR',
  TRANSFERT_SORTIE = 'TRANSFERT_SORTIE',
  TRANSFERT_ENTREE = 'TRANSFERT_ENTREE',
  AJUSTEMENT_INVENTAIRE = 'AJUSTEMENT_INVENTAIRE',
  PERTE_CASSE = 'PERTE_CASSE',
}

export class StockDto {
  @ApiProperty() productId!: string;
  @ApiProperty() locationId!: string;
  @ApiProperty({ example: '80.000' }) quantity!: string;
  @ApiProperty({ example: '10.000' }) reservedQuantity!: string;
  @ApiProperty({ example: '0.000' }) inTransitQuantity!: string;
  @ApiProperty({
    example: '70.000',
    description: 'quantity − reservedQuantity — c’est CE chiffre qui autorise une vente.',
  })
  availableQuantity!: string;
}

export class StockMovementDto {
  @ApiProperty() id!: string;
  @ApiProperty() productId!: string;
  @ApiProperty() locationId!: string;
  @ApiProperty({
    example: '-3.000',
    description: 'Delta SIGNÉ appliqué à la projection. Source de vérité du stock.',
  })
  quantity!: string;
  @ApiProperty({ enum: StockMovementTypeDto }) type!: StockMovementTypeDto;
  @ApiProperty({ nullable: true }) operationId!: string | null;
  @ApiProperty() createdAt!: Date;
}

export class DeclareLossDto {
  @ApiProperty() @IsUUID() productId!: string;
  @ApiProperty() @IsUUID() locationId!: string;
  @ApiProperty({ example: '2.000', description: 'Quantité perdue (positive)' })
  @IsNumberString()
  quantity!: string;
  @ApiProperty({ enum: StockMovementTypeDto, example: StockMovementTypeDto.PERTE_CASSE })
  @IsEnum(StockMovementTypeDto)
  type!: StockMovementTypeDto;
  @ApiPropertyOptional() @IsString() @IsOptional() comment?: string;
  @ApiPropertyOptional({ description: 'UUID d’idempotence pour une saisie hors-ligne' })
  @IsUUID()
  @IsOptional()
  clientMutationId?: string;
}

/// CONTRAT FIGÉ — implémentation avec la feature P0 n°3 « Stock ».
@ApiTags('Stock')
@ApiBearerAuth()
@Controller('stock')
export class StockController {
  @Roles(...ALL_ROLES)
  @RequirePermissions(PERMISSIONS.STOCK_READ_STORE)
  @Get()
  @ApiOperation({
    summary: 'Stock par produit et emplacement',
    description: 'Projection lue depuis `Stock`, alimentée par les mouvements.',
  })
  @ApiOkResponse({ type: [StockDto] })
  findAll(@Query() _query: PaginationQueryDto): Promise<StockDto[]> {
    return notImplemented('Stock');
  }

  @Roles(...ALL_ROLES)
  @RequirePermissions(PERMISSIONS.STOCK_READ_STORE)
  @Get('movements')
  @ApiOperation({
    summary: 'Journal des mouvements (source de vérité)',
    description: 'Historique immuable : aucun mouvement n’est jamais supprimé.',
  })
  @ApiOkResponse({ type: [StockMovementDto] })
  movements(@Query() _query: PaginationQueryDto): Promise<StockMovementDto[]> {
    return notImplemented('Stock');
  }

  @Roles(RoleCode.ADMIN, RoleCode.MAGASINIER)
  @RequirePermissions(PERMISSIONS.STOCK_LOSS)
  @Post('losses')
  @ApiOperation({
    summary: 'Déclare une perte ou une casse',
    description:
      'Crée un mouvement négatif et met à jour la projection dans la même transaction.',
  })
  @ApiOkResponse({ type: StockMovementDto })
  declareLoss(@Body() _dto: DeclareLossDto): Promise<StockMovementDto> {
    return notImplemented('Stock');
  }
}
