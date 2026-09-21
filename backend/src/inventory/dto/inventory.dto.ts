import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import { Transform, Type } from 'class-transformer';
import {
  ArrayMaxSize,
  ArrayNotEmpty,
  IsArray,
  IsBoolean,
  IsEnum,
  IsOptional,
  IsString,
  Matches,
  MaxLength,
  ValidateNested,
} from 'class-validator';
import {
  PaginationMetaDto,
  PaginationQueryDto,
} from '../../common/dto/pagination.dto';
import { ClientMutationId } from '../../common/idempotency';
import { IsCanonicalUuid } from '../../common/validation';

/// Quantités comptées : décimales à 3 décimales au plus (règle 10), en CHAÎNE.
/// Motif PROPRE à ce DTO, volontairement plus strict que `parseQuantity` : il
/// refuse le signe négatif. On ne compte pas « moins trois » sur une étagère ;
/// l'écart, lui, peut être négatif, mais il est calculé par le serveur.
/// Ne pas « factoriser » avec celui de `common/quantity.ts` : ce serait perdre
/// cette protection.
const QUANTITY_PATTERN = /^\d{1,11}(\.\d{1,3})?$/;

export enum InventoryTypeDto {
  COMPLET = 'COMPLET',
  TOURNANT = 'TOURNANT',
}

export class CreateInventoryDto {
  @ApiPropertyOptional({ description: 'UUID généré par le client.' })
  @IsCanonicalUuid()
  @IsOptional()
  id?: string;

  @ApiProperty({ description: 'Lieu compté : MAGASIN ou DEPOT.' })
  @IsCanonicalUuid()
  locationId!: string;

  @ApiProperty({ enum: InventoryTypeDto, default: InventoryTypeDto.COMPLET })
  @IsEnum(InventoryTypeDto)
  type!: InventoryTypeDto;

  @ApiPropertyOptional({
    description: 'Libellé de la zone comptée (inventaire tournant).',
  })
  @Transform(({ value }: { value: unknown }) =>
    typeof value === 'string' ? value.trim() || null : value,
  )
  @IsString()
  @MaxLength(100)
  @IsOptional()
  zone?: string | null;

  @ApiPropertyOptional({
    description:
      'Produits à compter. Obligatoire pour un inventaire TOURNANT ; ' +
      'interdit pour un COMPLET, qui fige tout ce que le lieu porte.',
    type: [String],
  })
  @IsArray()
  @ArrayNotEmpty()
  @ArrayMaxSize(1000)
  @IsCanonicalUuid({ each: true })
  @IsOptional()
  productIds?: string[];

  @ApiPropertyOptional()
  @Transform(({ value }: { value: unknown }) =>
    typeof value === 'string' ? value.trim() || null : value,
  )
  @IsString()
  @MaxLength(500)
  @IsOptional()
  note?: string | null;

  /// Un inventaire relancé deux fois par erreur figerait deux fois le
  /// théorique : clé obligatoire, comme toute création suivie.
  @ClientMutationId() clientMutationId!: string;
}

export class CountLineDto {
  @ApiProperty() @IsCanonicalUuid() productId!: string;

  @ApiProperty({
    example: '47.500',
    description: 'Quantité PHYSIQUEMENT comptée (décimale, 3 décimales max).',
    pattern: '^\\d{1,11}(\\.\\d{1,3})?$',
  })
  @IsString()
  @MaxLength(20)
  @Matches(QUANTITY_PATTERN, {
    message: 'countedQuantity : décimale à 3 décimales au plus attendue',
  })
  countedQuantity!: string;
}

export class SubmitCountDto {
  @ApiProperty({ type: [CountLineDto] })
  @IsArray()
  @ArrayNotEmpty()
  @ArrayMaxSize(1000)
  @ValidateNested({ each: true })
  @Type(() => CountLineDto)
  lines!: CountLineDto[];

  @ApiPropertyOptional({
    default: false,
    description:
      'false = comptage en cours (EN_COURS), reprise possible. true = ' +
      'comptage terminé (TERMINE), prêt pour la validation de l’administrateur.',
  })
  @IsBoolean()
  @IsOptional()
  done?: boolean;
}

export class InventoryLineDto {
  @ApiProperty() id!: string;
  @ApiProperty() productId!: string;
  @ApiProperty({
    example: '50.000',
    description: 'Ce que le système croyait AU MOMENT DU COMPTAGE.',
  })
  theoreticalQuantity!: string;
  @ApiProperty({ example: '47.500', nullable: true })
  countedQuantity!: string | null;
  @ApiProperty({ example: '-2.500', description: 'compté − théorique' })
  difference!: string;
  @ApiProperty({ example: 'ECART', description: 'CONFORME | ECART' })
  state!: string;
  @ApiProperty({ nullable: true }) note!: string | null;
}

export class InventoryDto {
  @ApiProperty() id!: string;
  @ApiProperty({ example: 'INV-2026-00001' }) number!: string;
  @ApiProperty({ example: 'EN_COURS', description: 'EN_COURS → TERMINE' })
  status!: string;
  @ApiProperty({ enum: InventoryTypeDto }) type!: InventoryTypeDto;
  @ApiProperty() locationId!: string;
  @ApiProperty({ nullable: true }) zone!: string | null;
  @ApiProperty() createdById!: string;
  @ApiProperty({ nullable: true }) validatedById!: string | null;
  @ApiProperty() startedAt!: Date;
  @ApiProperty({ nullable: true }) completedAt!: Date | null;
  @ApiProperty({ nullable: true }) validatedAt!: Date | null;
  @ApiProperty({ nullable: true }) note!: string | null;
  @ApiProperty() updatedAt!: Date;
  @ApiProperty({ type: [InventoryLineDto] }) lines!: InventoryLineDto[];
}

export class InventoryListQueryDto extends PaginationQueryDto {
  @ApiPropertyOptional({ description: 'EN_COURS ou TERMINE.' })
  @IsString()
  @MaxLength(20)
  @IsOptional()
  status?: string;
}

export class InventoryListDto {
  @ApiProperty({ type: [InventoryDto] }) data!: InventoryDto[];
  @ApiProperty({ type: PaginationMetaDto }) meta!: PaginationMetaDto;
}
