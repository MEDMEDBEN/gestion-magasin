import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import { Transform } from 'class-transformer';
import {
  IsBoolean,
  IsIn,
  IsOptional,
  IsString,
  Matches,
  MaxLength,
  MinLength,
} from 'class-validator';
import { booleanQuery } from '../../common/validation';

/// Paramètres de prix (P1 bis n°21h) : tarifs et taux de TVA, gérés par
/// l'ADMIN (`price.manage`). Un seul élément par défaut ; le défaut ne se
/// désactive pas (on en désigne d'abord un autre).

const trim = ({ value }: { value: unknown }) =>
  typeof value === 'string' ? value.trim() : value;
const upper = ({ value }: { value: unknown }) =>
  typeof value === 'string' ? value.trim().toUpperCase() : value;

const CODE = /^[A-Z0-9_]{2,20}$/;
const CODE_MESSAGE = 'code : 2 à 20 lettres, chiffres ou _ (ex. GROS)';

/// Taux en pourcentage, 0 à 100, deux décimales au plus (« 19 », « 9.5 »).
const RATE = /^(100(\.0{1,2})?|\d{1,2}(\.\d{1,2})?)$/;
const RATE_MESSAGE = 'rate : pourcentage de 0 à 100, 2 décimales au plus';

export class ListPricingQueryDto {
  @ApiPropertyOptional({
    description: 'Vrai : inactifs compris (écran Paramètres).',
  })
  @Transform(booleanQuery)
  @IsBoolean()
  @IsOptional()
  includeInactive?: boolean;
}

export class CreatePriceTierDto {
  @ApiProperty({ example: 'REVENDEUR' })
  @Transform(upper)
  @IsString()
  @Matches(CODE, { message: CODE_MESSAGE })
  code!: string;

  @ApiProperty({ example: 'Revendeur' })
  @Transform(trim)
  @IsString()
  @MinLength(2)
  @MaxLength(60)
  name!: string;
}

export class UpdatePriceTierDto {
  @ApiPropertyOptional()
  @Transform(trim)
  @IsString()
  @MinLength(2)
  @MaxLength(60)
  @IsOptional()
  name?: string;

  @ApiPropertyOptional({
    description: 'Seul `true` : désigner un autre défaut retire l’ancien.',
  })
  @IsIn([true])
  @IsOptional()
  isDefault?: true;

  @ApiPropertyOptional()
  @IsBoolean()
  @IsOptional()
  isActive?: boolean;
}

export class CreateTaxRateDto {
  @ApiProperty({ example: 'TVA9' })
  @Transform(upper)
  @IsString()
  @Matches(CODE, { message: CODE_MESSAGE })
  code!: string;

  @ApiProperty({ example: 'TVA 9 %' })
  @Transform(trim)
  @IsString()
  @MinLength(2)
  @MaxLength(60)
  name!: string;

  @ApiProperty({ example: '9.00', description: 'Pourcentage, en chaîne.' })
  @IsString()
  @Matches(RATE, { message: RATE_MESSAGE })
  rate!: string;
}

export class UpdateTaxRateDto {
  @ApiPropertyOptional()
  @Transform(trim)
  @IsString()
  @MinLength(2)
  @MaxLength(60)
  @IsOptional()
  name?: string;

  @ApiPropertyOptional({
    description:
      'Nouveau taux : vaut pour les ventes FUTURES (chaque ligne vendue garde ' +
      'le taux de son jour).',
  })
  @IsString()
  @Matches(RATE, { message: RATE_MESSAGE })
  @IsOptional()
  rate?: string;

  @ApiPropertyOptional({ description: 'Seul `true`.' })
  @IsIn([true])
  @IsOptional()
  isDefault?: true;

  @ApiPropertyOptional()
  @IsBoolean()
  @IsOptional()
  isActive?: boolean;
}
