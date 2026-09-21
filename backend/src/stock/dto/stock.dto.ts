import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import { Transform } from 'class-transformer';
import {
  IsEnum,
  IsISO8601,
  IsOptional,
  IsString,
  MaxLength,
} from 'class-validator';
import {
  PaginationMetaDto,
  PaginationQueryDto,
} from '../../common/dto/pagination.dto';
import { ClientGeneratedId, IsCanonicalUuid } from '../../common/validation';

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

export enum StockLossStatusDto {
  EN_ATTENTE = 'EN_ATTENTE',
  VALIDEE = 'VALIDEE',
  REFUSEE = 'REFUSEE',
}

const trimOrNull = ({ value }: { value: unknown }) =>
  typeof value === 'string' ? value.trim() || null : value;

export class StockQueryDto extends PaginationQueryDto {
  @ApiPropertyOptional() @IsCanonicalUuid() @IsOptional() productId?: string;
  @ApiPropertyOptional() @IsCanonicalUuid() @IsOptional() locationId?: string;
}

export class StockDto {
  @ApiProperty() productId!: string;
  @ApiProperty() locationId!: string;
  @ApiProperty({ example: '80.000' }) quantity!: string;
  @ApiProperty({ example: '10.000' }) reservedQuantity!: string;
  @ApiProperty({ example: '0.000' }) inTransitQuantity!: string;
  @ApiProperty({
    example: '70.000',
    description:
      'quantity − reservedQuantity — c’est CE chiffre qui autorise une vente.',
  })
  availableQuantity!: string;
  @ApiProperty() updatedAt!: Date;
}

export class StockListDto {
  @ApiProperty({ type: [StockDto] }) data!: StockDto[];
  @ApiProperty({ type: PaginationMetaDto }) meta!: PaginationMetaDto;
}

export class MovementQueryDto extends PaginationQueryDto {
  @ApiPropertyOptional() @IsCanonicalUuid() @IsOptional() productId?: string;
  @ApiPropertyOptional() @IsCanonicalUuid() @IsOptional() locationId?: string;
  @ApiPropertyOptional({ enum: StockMovementTypeDto })
  @IsEnum(StockMovementTypeDto)
  @IsOptional()
  type?: StockMovementTypeDto;
  @ApiPropertyOptional({ description: 'Depuis (ISO 8601, inclus)' })
  @IsISO8601({ strict: true, strictSeparator: true })
  @IsOptional()
  from?: string;
  @ApiPropertyOptional({ description: 'Jusqu’à (ISO 8601, exclu)' })
  @IsISO8601({ strict: true, strictSeparator: true })
  @IsOptional()
  to?: string;
}

export class StockMovementDto {
  @ApiProperty() id!: string;
  @ApiProperty() productId!: string;
  @ApiProperty() locationId!: string;
  @ApiProperty({
    example: '-3.000',
    description:
      'Delta SIGNÉ appliqué à la projection. Source de vérité du stock.',
  })
  quantity!: string;
  @ApiProperty({ enum: StockMovementTypeDto }) type!: StockMovementTypeDto;
  @ApiProperty() operationType!: string;
  @ApiProperty({ nullable: true }) operationId!: string | null;
  @ApiProperty({ nullable: true }) userId!: string | null;
  @ApiProperty({ nullable: true }) comment!: string | null;
  @ApiProperty() createdAt!: Date;
}

export class StockMovementListDto {
  @ApiProperty({ type: [StockMovementDto] }) data!: StockMovementDto[];
  @ApiProperty({ type: PaginationMetaDto }) meta!: PaginationMetaDto;
}

export class DeclareLossDto {
  @ApiPropertyOptional({
    description:
      'UUID généré par le client (contrat de sync). Absent → généré serveur.',
  })
  @ClientGeneratedId()
  id?: string;

  @ApiProperty() @IsCanonicalUuid() productId!: string;
  @ApiProperty() @IsCanonicalUuid() locationId!: string;

  @ApiProperty({
    example: '2.000',
    description: 'Quantité perdue, POSITIVE, décimale en chaîne.',
  })
  @IsString()
  @MaxLength(20)
  quantity!: string;

  @ApiPropertyOptional()
  @Transform(trimOrNull)
  @IsString()
  @MaxLength(500)
  @IsOptional()
  comment?: string | null;
}

export class RejectLossDto {
  @ApiPropertyOptional({ description: 'Motif du refus, montré au déclarant' })
  @Transform(trimOrNull)
  @IsString()
  @MaxLength(500)
  @IsOptional()
  note?: string | null;
}

export class LossQueryDto extends PaginationQueryDto {
  @ApiPropertyOptional({ enum: StockLossStatusDto })
  @IsEnum(StockLossStatusDto)
  @IsOptional()
  status?: StockLossStatusDto;
}

export class StockLossDto {
  @ApiProperty() id!: string;
  @ApiProperty() productId!: string;
  @ApiProperty() locationId!: string;
  @ApiProperty({ example: '2.000' }) quantity!: string;
  @ApiProperty({ nullable: true }) comment!: string | null;
  @ApiProperty({ enum: StockLossStatusDto }) status!: StockLossStatusDto;
  @ApiProperty() declaredById!: string;
  @ApiProperty({ nullable: true }) decidedById!: string | null;
  @ApiProperty({ nullable: true }) decidedAt!: Date | null;
  @ApiProperty({ nullable: true }) decisionNote!: string | null;
  @ApiProperty({
    nullable: true,
    description: 'Mouvement appliqué une fois validée',
  })
  movementId!: string | null;
  @ApiProperty() createdAt!: Date;
}

export class StockLossListDto {
  @ApiProperty({ type: [StockLossDto] }) data!: StockLossDto[];
  @ApiProperty({ type: PaginationMetaDto }) meta!: PaginationMetaDto;
}
