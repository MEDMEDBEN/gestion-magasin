import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import { Transform } from 'class-transformer';
import {
  IsBoolean,
  IsEnum,
  IsOptional,
  IsString,
  IsUUID,
  Matches,
  MaxLength,
  MinLength,
} from 'class-validator';
import { IsOptionalNotNull } from '../../common/validation';

/// Aligné sur l'enum `LocationType` du schéma Prisma.
export enum LocationTypeDto {
  MAGASIN = 'MAGASIN',
  DEPOT = 'DEPOT',
  TRANSIT = 'TRANSIT',
  EMPLACEMENT = 'EMPLACEMENT',
}

const trimOrNull = ({ value }: { value: unknown }) =>
  typeof value === 'string' ? value.trim() || null : value;
const upperTrim = ({ value }: { value: unknown }) =>
  typeof value === 'string' ? value.trim().toUpperCase() : value;

const CODE_PATTERN = /^[A-Z0-9][A-Z0-9._-]{0,39}$/;
const CODE_MESSAGE = 'Code : lettres, chiffres, « . », « _ », « - » (40 max)';
const PART_MAX_LENGTH = 20;

export class CreateLocationDto {
  @ApiPropertyOptional({
    description: 'UUID généré par le client. Absent → généré serveur.',
  })
  @IsUUID()
  @IsOptional()
  id?: string;

  @ApiPropertyOptional({
    example: 'A-02-04-03',
    description: 'Absent → dérivé de zone-rayon-étagère-position.',
  })
  @Transform(upperTrim)
  @IsOptional()
  @Matches(CODE_PATTERN, { message: CODE_MESSAGE })
  code?: string;

  @ApiPropertyOptional({
    example: 'Zone A · Rayon 02 · Étagère 04 · Position 03',
    description: 'Absent → dérivé de la structure.',
  })
  @Transform(trimOrNull)
  @IsString()
  @MinLength(2)
  @MaxLength(100)
  @IsOptional()
  name?: string;

  @ApiPropertyOptional({
    enum: LocationTypeDto,
    default: LocationTypeDto.EMPLACEMENT,
    description:
      'Seul EMPLACEMENT se crée : MAGASIN, DEPOT et TRANSIT sont uniques.',
  })
  @IsEnum(LocationTypeDto)
  @IsOptional()
  type?: LocationTypeDto;

  @ApiPropertyOptional({ description: 'DEPOT parent. Absent → le dépôt.' })
  @IsUUID()
  @IsOptional()
  parentId?: string;

  @ApiPropertyOptional({ example: 'A' })
  @Transform(trimOrNull)
  @IsString()
  @MaxLength(PART_MAX_LENGTH)
  @IsOptional()
  zone?: string;
  @ApiPropertyOptional({ example: '02' })
  @Transform(trimOrNull)
  @IsString()
  @MaxLength(PART_MAX_LENGTH)
  @IsOptional()
  aisle?: string;
  @ApiPropertyOptional({ example: '04' })
  @Transform(trimOrNull)
  @IsString()
  @MaxLength(PART_MAX_LENGTH)
  @IsOptional()
  shelf?: string;
  @ApiPropertyOptional({ example: '03' })
  @Transform(trimOrNull)
  @IsString()
  @MaxLength(PART_MAX_LENGTH)
  @IsOptional()
  position?: string;
}

/// Renommer, recoder, déplacer dans la structure, désactiver. Le code n'est
/// JAMAIS recalculé automatiquement : il peut être imprimé sur une étiquette.
export class UpdateLocationDto {
  @ApiPropertyOptional()
  @Transform(upperTrim)
  @IsOptionalNotNull()
  @Matches(CODE_PATTERN, { message: CODE_MESSAGE })
  code?: string;

  @ApiPropertyOptional()
  @Transform(({ value }) => (typeof value === 'string' ? value.trim() : value))
  @IsOptionalNotNull()
  @IsString()
  @MinLength(2)
  @MaxLength(100)
  name?: string;

  @ApiPropertyOptional({ nullable: true })
  @Transform(trimOrNull)
  @IsString()
  @MaxLength(PART_MAX_LENGTH)
  @IsOptional()
  zone?: string | null;
  @ApiPropertyOptional({ nullable: true })
  @Transform(trimOrNull)
  @IsString()
  @MaxLength(PART_MAX_LENGTH)
  @IsOptional()
  aisle?: string | null;
  @ApiPropertyOptional({ nullable: true })
  @Transform(trimOrNull)
  @IsString()
  @MaxLength(PART_MAX_LENGTH)
  @IsOptional()
  shelf?: string | null;
  @ApiPropertyOptional({ nullable: true })
  @Transform(trimOrNull)
  @IsString()
  @MaxLength(PART_MAX_LENGTH)
  @IsOptional()
  position?: string | null;

  @ApiPropertyOptional() @IsOptionalNotNull() @IsBoolean() isActive?: boolean;
}

export class LocationDto {
  @ApiProperty() id!: string;
  @ApiProperty() code!: string;
  @ApiProperty() name!: string;
  @ApiProperty({ enum: LocationTypeDto }) type!: LocationTypeDto;
  @ApiProperty({ nullable: true }) parentId!: string | null;
  @ApiProperty({ nullable: true }) zone!: string | null;
  @ApiProperty({ nullable: true }) aisle!: string | null;
  @ApiProperty({ nullable: true }) shelf!: string | null;
  @ApiProperty({ nullable: true }) position!: string | null;
  @ApiProperty() isActive!: boolean;
  @ApiProperty() updatedAt!: Date;
}
