import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import { Transform } from 'class-transformer';
import {
  IsBoolean,
  IsEnum,
  IsInt,
  IsOptional,
  IsString,
  MaxLength,
  Min,
  MinLength,
} from 'class-validator';
import {
  PaginationMetaDto,
  PaginationQueryDto,
} from '../../common/dto/pagination.dto';
import { IsCanonicalUuid, IsOptionalNotNull } from '../../common/validation';

/// Doit rester aligné sur l'enum `ProductUnit` du schéma Prisma.
export enum ProductUnitDto {
  PIECE = 'PIECE',
  METRE = 'METRE',
  ROULEAU = 'ROULEAU',
  BOITE = 'BOITE',
  PAQUET = 'PAQUET',
  KILOGRAMME = 'KILOGRAMME',
}

const trim = ({ value }: { value: unknown }) =>
  typeof value === 'string' ? value.trim() : value;
/// Texte facultatif effaçable : chaîne vide → `null`.
const trimOrNull = ({ value }: { value: unknown }) =>
  typeof value === 'string' ? value.trim() || null : value;
/// Query string : seul « true » vaut vrai.
const booleanQuery = ({ value }: { value: unknown }) =>
  value === true || value === 'true';

export const SKU_MAX_LENGTH = 50;
export const NAME_MAX_LENGTH = 150;
export const TEXT_MAX_LENGTH = 1000;
export const BRAND_MAX_LENGTH = 80;

export class CreateProductDto {
  @ApiPropertyOptional({
    description:
      'UUID généré par le client (contrat de sync). Absent → généré serveur.',
  })
  @IsCanonicalUuid()
  @IsOptional()
  id?: string;

  @ApiProperty({ example: 'CAB-3G25' })
  @Transform(trim)
  @IsString()
  @MinLength(1)
  @MaxLength(SKU_MAX_LENGTH)
  sku!: string;

  @ApiPropertyOptional({
    description:
      'Code fabricant scanné. Absent → code interne EAN-13 (préfixe 20) généré par le serveur.',
  })
  @IsString()
  @IsOptional()
  @MaxLength(64)
  barcode?: string;

  @ApiProperty({ example: 'Câble 3G2.5 souple' })
  @Transform(trim)
  @IsString()
  @MinLength(2)
  @MaxLength(NAME_MAX_LENGTH)
  name!: string;

  @ApiPropertyOptional()
  @Transform(trimOrNull)
  @IsString()
  @IsOptional()
  @MaxLength(TEXT_MAX_LENGTH)
  description?: string | null;

  @ApiPropertyOptional()
  @Transform(trimOrNull)
  @IsString()
  @IsOptional()
  @MaxLength(BRAND_MAX_LENGTH)
  brand?: string | null;

  @ApiProperty({ enum: ProductUnitDto, default: ProductUnitDto.PIECE })
  @IsEnum(ProductUnitDto)
  unit!: ProductUnitDto;

  @ApiPropertyOptional() @IsCanonicalUuid() @IsOptional() categoryId?:
    string | null;
  @ApiPropertyOptional() @IsCanonicalUuid() @IsOptional() taxRateId?:
    string | null;
  @ApiPropertyOptional() @IsCanonicalUuid() @IsOptional() mainSupplierId?:
    string | null;
  @ApiPropertyOptional({
    description: 'Emplacement physique au dépôt (type EMPLACEMENT)',
  })
  @IsCanonicalUuid()
  @IsOptional()
  storageLocationId?: string | null;

  @ApiPropertyOptional({
    example: '10.000',
    description: 'Quantité DÉCIMALE ≥ 0 transmise en chaîne — jamais un float.',
  })
  @IsString()
  @IsOptional()
  @MaxLength(20)
  minThreshold?: string;

  @ApiPropertyOptional({ example: '5.000' })
  @IsString()
  @IsOptional()
  @MaxLength(20)
  safetyStock?: string;

  @ApiPropertyOptional({
    default: false,
    description:
      'Autorise une vente qui rendrait le stock négatif (backorder).',
  })
  @IsBoolean()
  @IsOptional()
  allowBackorder?: boolean;
}

/// Modification partielle. Les champs obligatoires ne sont jamais `null` ; les
/// rattachements facultatifs (catégorie, TVA…) acceptent `null` = retirer.
export class UpdateProductDto {
  @ApiPropertyOptional()
  @Transform(trim)
  @IsOptionalNotNull()
  @IsString()
  @MinLength(1)
  @MaxLength(SKU_MAX_LENGTH)
  sku?: string;

  @ApiPropertyOptional({ description: 'Correction d’un code mal saisi.' })
  @IsOptionalNotNull()
  @IsString()
  @MaxLength(64)
  barcode?: string;

  @ApiPropertyOptional()
  @Transform(trim)
  @IsOptionalNotNull()
  @IsString()
  @MinLength(2)
  @MaxLength(NAME_MAX_LENGTH)
  name?: string;

  @ApiPropertyOptional({ nullable: true })
  @Transform(trimOrNull)
  @IsString()
  @IsOptional()
  @MaxLength(TEXT_MAX_LENGTH)
  description?: string | null;

  @ApiPropertyOptional({ nullable: true })
  @Transform(trimOrNull)
  @IsString()
  @IsOptional()
  @MaxLength(BRAND_MAX_LENGTH)
  brand?: string | null;

  @ApiPropertyOptional({ enum: ProductUnitDto })
  @IsOptionalNotNull()
  @IsEnum(ProductUnitDto)
  unit?: ProductUnitDto;

  @ApiPropertyOptional({ nullable: true })
  @IsCanonicalUuid()
  @IsOptional()
  categoryId?: string | null;
  @ApiPropertyOptional({ nullable: true })
  @IsCanonicalUuid()
  @IsOptional()
  taxRateId?: string | null;
  @ApiPropertyOptional({ nullable: true })
  @IsCanonicalUuid()
  @IsOptional()
  mainSupplierId?: string | null;
  @ApiPropertyOptional({ nullable: true })
  @IsCanonicalUuid()
  @IsOptional()
  storageLocationId?: string | null;

  @ApiPropertyOptional()
  @IsOptionalNotNull()
  @IsString()
  @MaxLength(20)
  minThreshold?: string;
  @ApiPropertyOptional()
  @IsOptionalNotNull()
  @IsString()
  @MaxLength(20)
  safetyStock?: string;
  @ApiPropertyOptional()
  @IsOptionalNotNull()
  @IsBoolean()
  allowBackorder?: boolean;

  @ApiPropertyOptional({
    description: 'Exige en plus la permission `product.disable`.',
  })
  @IsOptionalNotNull()
  @IsBoolean()
  isActive?: boolean;
}

export class ProductListQueryDto extends PaginationQueryDto {
  @ApiPropertyOptional({
    description: 'Filtre catégorie (sous-catégories incluses)',
  })
  @IsCanonicalUuid()
  @IsOptional()
  categoryId?: string;

  @ApiPropertyOptional({
    default: false,
    description: 'Inclure les produits désactivés',
  })
  @Transform(booleanQuery)
  @IsBoolean()
  @IsOptional()
  includeInactive = false;
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
  @ApiProperty({ nullable: true }) mainSupplierId!: string | null;
  @ApiProperty({ nullable: true }) storageLocationId!: string | null;
  @ApiProperty({ example: '10.000' }) minThreshold!: string;
  @ApiProperty({ example: '5.000' }) safetyStock!: string;
  @ApiProperty({
    nullable: true,
    description:
      'Dernier prix d’achat réceptionné, en centimes (base de la marge).',
  })
  lastPurchasePriceHt!: number | null;
  @ApiProperty() allowBackorder!: boolean;
  @ApiProperty() isActive!: boolean;
  @ApiProperty() updatedAt!: Date;
}

export class ProductListDto {
  @ApiProperty({ type: [ProductDto] }) data!: ProductDto[];
  @ApiProperty({ type: PaginationMetaDto }) meta!: PaginationMetaDto;
}

export class CreateCategoryDto {
  @ApiPropertyOptional({
    description: 'UUID généré par le client. Absent → généré serveur.',
  })
  @IsCanonicalUuid()
  @IsOptional()
  id?: string;

  @ApiProperty()
  @Transform(trim)
  @IsString()
  @MinLength(2)
  @MaxLength(80)
  name!: string;

  @ApiPropertyOptional({
    description: 'Catégorie racine parente (2 niveaux maximum)',
  })
  @IsCanonicalUuid()
  @IsOptional()
  parentId?: string | null;

  @ApiPropertyOptional()
  @Transform(trimOrNull)
  @IsString()
  @IsOptional()
  @MaxLength(TEXT_MAX_LENGTH)
  description?: string | null;
}

export class UpdateCategoryDto {
  @ApiPropertyOptional()
  @Transform(trim)
  @IsOptionalNotNull()
  @IsString()
  @MinLength(2)
  @MaxLength(80)
  name?: string;

  @ApiPropertyOptional({
    nullable: true,
    description: '`null` = devient racine',
  })
  @IsCanonicalUuid()
  @IsOptional()
  parentId?: string | null;

  @ApiPropertyOptional({ nullable: true })
  @Transform(trimOrNull)
  @IsString()
  @IsOptional()
  @MaxLength(TEXT_MAX_LENGTH)
  description?: string | null;

  @ApiPropertyOptional() @IsOptionalNotNull() @IsBoolean() isActive?: boolean;
}

export class CategoryDto {
  @ApiProperty() id!: string;
  @ApiProperty() name!: string;
  @ApiProperty({ nullable: true }) parentId!: string | null;
  @ApiProperty({ nullable: true }) description!: string | null;
  @ApiProperty() isActive!: boolean;
  @ApiProperty() updatedAt!: Date;
}

export class SetProductPriceDto {
  @ApiProperty({ description: 'Tarif concerné (DETAIL, GROS…)' })
  @IsCanonicalUuid()
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
  @ApiProperty({ example: '19.00', description: 'Taux en pourcentage' })
  rate!: string;
  @ApiProperty() isDefault!: boolean;
  @ApiProperty() isActive!: boolean;
  @ApiProperty() updatedAt!: Date;
}
