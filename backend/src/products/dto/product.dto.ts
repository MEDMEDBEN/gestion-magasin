import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import {
  IsBoolean,
  IsEnum,
  IsInt,
  IsNumberString,
  IsOptional,
  IsString,
  IsUUID,
  Min,
  MinLength,
} from 'class-validator';

/// Doit rester aligné sur l'enum `ProductUnit` du schéma Prisma.
export enum ProductUnitDto {
  PIECE = 'PIECE',
  METRE = 'METRE',
  ROULEAU = 'ROULEAU',
  BOITE = 'BOITE',
  PAQUET = 'PAQUET',
  KILOGRAMME = 'KILOGRAMME',
}

export class CreateProductDto {
  @ApiPropertyOptional({
    description: 'UUID généré par le client (contrat de sync). Absent → généré serveur.',
  })
  @IsUUID()
  @IsOptional()
  id?: string;

  @ApiProperty({ example: 'CAB-3G25' })
  @IsString()
  @MinLength(1)
  sku!: string;

  @ApiPropertyOptional({
    description:
      'Code fabricant scanné. Absent → code interne unique généré par le serveur.',
  })
  @IsString()
  @IsOptional()
  barcode?: string;

  @ApiProperty({ example: 'Câble 3G2.5 souple' })
  @IsString()
  @MinLength(2)
  name!: string;

  @ApiPropertyOptional() @IsString() @IsOptional() description?: string;
  @ApiPropertyOptional() @IsString() @IsOptional() brand?: string;

  @ApiProperty({ enum: ProductUnitDto, default: ProductUnitDto.PIECE })
  @IsEnum(ProductUnitDto)
  unit!: ProductUnitDto;

  @ApiPropertyOptional() @IsUUID() @IsOptional() categoryId?: string;
  @ApiPropertyOptional() @IsUUID() @IsOptional() taxRateId?: string;
  @ApiPropertyOptional() @IsUUID() @IsOptional() mainSupplierId?: string;
  @ApiPropertyOptional({ description: 'Emplacement physique au dépôt' })
  @IsUUID()
  @IsOptional()
  storageLocationId?: string;

  @ApiPropertyOptional({
    example: '10.000',
    description: 'Quantité DÉCIMALE transmise en chaîne — jamais un float.',
  })
  @IsNumberString()
  @IsOptional()
  minThreshold?: string;

  @ApiPropertyOptional({ example: '5.000' })
  @IsNumberString()
  @IsOptional()
  safetyStock?: string;

  @ApiPropertyOptional({
    default: false,
    description: 'Autorise une vente qui rendrait le stock négatif (backorder).',
  })
  @IsBoolean()
  @IsOptional()
  allowBackorder?: boolean;
}

export class UpdateProductDto {
  @ApiPropertyOptional() @IsString() @MinLength(2) @IsOptional() name?: string;
  @ApiPropertyOptional() @IsString() @IsOptional() description?: string;
  @ApiPropertyOptional() @IsString() @IsOptional() brand?: string;
  @ApiPropertyOptional({ enum: ProductUnitDto })
  @IsEnum(ProductUnitDto)
  @IsOptional()
  unit?: ProductUnitDto;
  @ApiPropertyOptional() @IsUUID() @IsOptional() categoryId?: string;
  @ApiPropertyOptional() @IsUUID() @IsOptional() taxRateId?: string;
  @ApiPropertyOptional() @IsUUID() @IsOptional() mainSupplierId?: string;
  @ApiPropertyOptional() @IsUUID() @IsOptional() storageLocationId?: string;
  @ApiPropertyOptional() @IsNumberString() @IsOptional() minThreshold?: string;
  @ApiPropertyOptional() @IsNumberString() @IsOptional() safetyStock?: string;
  @ApiPropertyOptional() @IsBoolean() @IsOptional() allowBackorder?: boolean;
  @ApiPropertyOptional() @IsBoolean() @IsOptional() isActive?: boolean;
}

export class ProductDto {
  @ApiProperty() id!: string;
  @ApiProperty() sku!: string;
  @ApiProperty() barcode!: string;
  @ApiProperty() name!: string;
  @ApiProperty({ nullable: true }) description!: string | null;
  @ApiProperty({ nullable: true }) brand!: string | null;
  @ApiProperty({ enum: ProductUnitDto }) unit!: ProductUnitDto;
  @ApiProperty({ nullable: true }) categoryId!: string | null;
  @ApiProperty({ nullable: true }) taxRateId!: string | null;
  @ApiProperty({ example: '10.000' }) minThreshold!: string;
  @ApiProperty({ example: '5.000' }) safetyStock!: string;
  @ApiProperty({
    nullable: true,
    description: 'Dernier prix d’achat réceptionné, en centimes (base de la marge).',
  })
  lastPurchasePriceHt!: number | null;
  @ApiProperty() allowBackorder!: boolean;
  @ApiProperty() isActive!: boolean;
}

export class CreateCategoryDto {
  @ApiProperty() @IsString() @MinLength(2) name!: string;
  @ApiPropertyOptional() @IsUUID() @IsOptional() parentId?: string;
  @ApiPropertyOptional() @IsString() @IsOptional() description?: string;
}

export class CategoryDto {
  @ApiProperty() id!: string;
  @ApiProperty() name!: string;
  @ApiProperty({ nullable: true }) parentId!: string | null;
  @ApiProperty() isActive!: boolean;
}

export class SetProductPriceDto {
  @ApiProperty({ description: 'Tarif concerné (DETAIL, GROS…)' })
  @IsUUID()
  priceTierId!: string;

  @ApiProperty({
    example: 145000,
    description: 'Prix HT en CENTIMES de DA — entier obligatoire.',
  })
  @IsInt()
  @Min(0)
  priceHt!: number;
}

export class ProductPriceDto {
  @ApiProperty() productId!: string;
  @ApiProperty() priceTierId!: string;
  @ApiProperty({ example: 145000 }) priceHt!: number;
}

export class PriceTierDto {
  @ApiProperty() id!: string;
  @ApiProperty({ example: 'DETAIL' }) code!: string;
  @ApiProperty() name!: string;
  @ApiProperty() isDefault!: boolean;
}

export class TaxRateDto {
  @ApiProperty() id!: string;
  @ApiProperty({ example: 'TVA19' }) code!: string;
  @ApiProperty() name!: string;
  @ApiProperty({ example: '19.00', description: 'Taux en pourcentage' }) rate!: string;
  @ApiProperty() isDefault!: boolean;
}
