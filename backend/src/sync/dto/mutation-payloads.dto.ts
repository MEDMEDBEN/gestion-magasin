import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import {
  IsEnum,
  IsNumberString,
  IsOptional,
  IsString,
  IsUUID,
  MaxLength,
} from 'class-validator';

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
  @IsUUID()
  @IsOptional()
  id?: string;

  @ApiProperty() @IsUUID() productId!: string;

  @ApiProperty() @IsUUID() locationId!: string;

  @ApiProperty({
    example: '3.000',
    description: 'Quantité perdue, POSITIVE. Le serveur applique le delta négatif.',
  })
  @IsNumberString()
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
