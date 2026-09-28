import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import { Transform, Type } from 'class-transformer';
import {
  ArrayMaxSize,
  ArrayNotEmpty,
  IsArray,
  IsOptional,
  IsString,
  MaxLength,
  MinLength,
  ValidateNested,
} from 'class-validator';
import { ClientMutationId } from '../../common/idempotency';
import { ClientGeneratedId, IsCanonicalUuid } from '../../common/validation';

export class SupplierReturnLineInputDto {
  @ApiProperty() @IsCanonicalUuid() productId!: string;

  @ApiProperty({ example: '2.000' })
  @IsString()
  @MaxLength(20)
  quantity!: string;
}

export class CreateSupplierReturnDto {
  @ApiProperty({ description: 'UUID généré par le client.' })
  @ClientGeneratedId()
  id!: string;

  @ClientMutationId()
  clientMutationId!: string;

  @ApiProperty() @IsCanonicalUuid() supplierId!: string;

  @ApiPropertyOptional({
    description:
      'Commande concernée (facultatif) : chaque produit renvoyé doit y avoir été réceptionné.',
  })
  @IsCanonicalUuid()
  @IsOptional()
  purchaseOrderId?: string;

  @ApiProperty({
    description: 'Lieu d’où part la marchandise (magasin ou dépôt).',
  })
  @IsCanonicalUuid()
  locationId!: string;

  @ApiProperty({ type: [SupplierReturnLineInputDto] })
  @IsArray()
  @ArrayNotEmpty()
  @ArrayMaxSize(200)
  @ValidateNested({ each: true })
  @Type(() => SupplierReturnLineInputDto)
  lines!: SupplierReturnLineInputDto[];

  @ApiProperty({ example: 'Lot défectueux' })
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

export class SupplierReturnDto {
  @ApiProperty() id!: string;
  @ApiProperty({ example: 'RF-2026-00001' }) number!: string;
  @ApiProperty() supplierId!: string;
  @ApiProperty({ nullable: true }) purchaseOrderId!: string | null;
  @ApiProperty() locationId!: string;
  @ApiProperty() totalHt!: number;
  @ApiProperty() totalTax!: number;
  @ApiProperty() totalTtc!: number;
  @ApiProperty() reason!: string;
  @ApiProperty() createdAt!: Date;
}
