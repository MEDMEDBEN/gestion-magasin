import { ApiProperty } from '@nestjs/swagger';
import { Transform, Type } from 'class-transformer';
import {
  ArrayMaxSize,
  ArrayNotEmpty,
  IsArray,
  IsIn,
  IsString,
  MaxLength,
  MinLength,
  ValidateNested,
} from 'class-validator';
import { ClientMutationId } from '../../common/idempotency';
import { ClientGeneratedId, IsCanonicalUuid } from '../../common/validation';

/// Retour client (P1 bis n°21l) : des lignes d'UNE vente reviennent.
/// `ESPECES` : l'argent sort de la caisse ouverte de celui qui enregistre ;
/// `DETTE` : le reste dû de la vente (vente à crédit) baisse du TTC rendu.
export const REFUND_METHODS = ['ESPECES', 'DETTE'] as const;

export class SaleReturnLineInputDto {
  @ApiProperty() @IsCanonicalUuid() saleLineId!: string;

  @ApiProperty({ example: '2.500', description: 'Quantité rendue, décimale.' })
  @IsString()
  @MaxLength(20)
  quantity!: string;
}

export class CreateSaleReturnDto {
  @ApiProperty({ description: 'UUID généré par le client.' })
  @ClientGeneratedId()
  id!: string;

  @ClientMutationId()
  clientMutationId!: string;

  @ApiProperty({ type: [SaleReturnLineInputDto] })
  @IsArray()
  @ArrayNotEmpty()
  @ArrayMaxSize(200)
  @ValidateNested({ each: true })
  @Type(() => SaleReturnLineInputDto)
  lines!: SaleReturnLineInputDto[];

  @ApiProperty({ enum: REFUND_METHODS })
  @IsIn(REFUND_METHODS)
  refundMethod!: (typeof REFUND_METHODS)[number];

  @ApiProperty({ example: 'Disjoncteur défectueux' })
  @Transform(({ value }: { value: unknown }) =>
    typeof value === 'string' ? value.trim() : value,
  )
  @IsString()
  @MinLength(2, {
    message: 'reason : motif obligatoire (2 caractères au moins)',
  })
  @MaxLength(300)
  reason!: string;
}

export class SaleReturnLineDto {
  @ApiProperty() saleLineId!: string;
  @ApiProperty() productId!: string;
  @ApiProperty({ example: '1.000' }) quantity!: string;
  @ApiProperty() lineTotalHt!: number;
  @ApiProperty() lineTaxAmount!: number;
  @ApiProperty() lineTotalTtc!: number;
}

export class SaleReturnDto {
  @ApiProperty() id!: string;
  @ApiProperty({ example: 'RC-2026-00001' }) number!: string;
  @ApiProperty({
    nullable: true,
    example: 'AV-2026-000001',
    description: 'Facture d’avoir : seulement si la vente est facturée.',
  })
  creditNoteNumber!: string | null;
  @ApiProperty() saleId!: string;
  @ApiProperty({ enum: REFUND_METHODS }) refundMethod!: string;
  @ApiProperty() totalHt!: number;
  @ApiProperty() totalTax!: number;
  @ApiProperty() totalTtc!: number;
  @ApiProperty() reason!: string;
  @ApiProperty() createdAt!: Date;
  @ApiProperty({ type: [SaleReturnLineDto] }) lines!: SaleReturnLineDto[];
}
