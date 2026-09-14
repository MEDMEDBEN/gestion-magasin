import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import {
  IsEnum,
  IsNumberString,
  IsOptional,
  IsString,
  MaxLength,
} from 'class-validator';
import { IsCanonicalUuid } from '../../common/validation';

/// Mouvements de stock déclarables hors-ligne aujourd'hui. Les autres types
/// (`VENTE`, `RECEPTION`, `TRANSFERT_*`, `AJUSTEMENT_INVENTAIRE`) arriveront avec
/// leur feature et leur propre handler — ils ne sont pas acceptés ici.
export enum SyncStockMovementTypeDto {
  PERTE_CASSE = 'PERTE_CASSE',
}

/// Payload de `operationType = MANUAL` : une perte ou une casse constatée au dépôt,
/// saisie éventuellement sans réseau. Miroir de `DeclareLossDto` (contrat en ligne).
export class StockLossPayloadDto {
  @ApiPropertyOptional({
    description:
      'UUID du mouvement, généré par l’appareil (contrat de sync §1). Absent → généré serveur.',
  })
  @IsCanonicalUuid()
  @IsOptional()
  id?: string;

  @ApiProperty() @IsCanonicalUuid() productId!: string;

  @ApiProperty() @IsCanonicalUuid() locationId!: string;

  @ApiProperty({
    example: '3.000',
    description:
      'Quantité perdue, POSITIVE. Le serveur applique le delta négatif.',
  })
  @IsNumberString()
  @MaxLength(20)
  quantity!: string;

  @ApiProperty({ enum: SyncStockMovementTypeDto })
  @IsEnum(SyncStockMovementTypeDto)
  type!: SyncStockMovementTypeDto;

  @ApiPropertyOptional()
  @IsString()
  @MaxLength(500)
  @IsOptional()
  comment?: string;
}
