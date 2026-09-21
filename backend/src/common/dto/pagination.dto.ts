import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import { Type } from 'class-transformer';
import {
  IsInt,
  IsOptional,
  IsString,
  Matches,
  Max,
  MaxLength,
  Min,
} from 'class-validator';
import { BusinessException } from '../business.exception';
import { ErrorCode } from '../error-codes';

/// Query de pagination commune à TOUTE liste : `?page=1&limit=50&sort=field:asc&q=...`
export class PaginationQueryDto {
  /// Borne HAUTE obligatoire : sans elle, `?page=1e308` passait `@IsInt`, le
  /// décalage `(page − 1) × limit` dépassait ce que Prisma accepte, et TOUTES
  /// les listes répondaient 500 (audit sécurité du 2026-09-21). Un million de
  /// pages de 200 lignes dépasse de très loin ce qu'un magasin produira.
  @ApiPropertyOptional({ default: 1, minimum: 1, maximum: 1_000_000 })
  @Type(() => Number)
  @IsInt()
  @Min(1)
  @Max(1_000_000)
  @IsOptional()
  page = 1;

  @ApiPropertyOptional({ default: 50, minimum: 1, maximum: 200 })
  @Type(() => Number)
  @IsInt()
  @Min(1)
  @Max(200)
  @IsOptional()
  limit = 50;

  @ApiPropertyOptional({ example: 'createdAt:desc' })
  @IsString()
  @Matches(/^[a-zA-Z0-9_.]+:(asc|desc)$/, {
    message: 'sort doit être au format `champ:asc` ou `champ:desc`',
  })
  @IsOptional()
  sort?: string;

  @ApiPropertyOptional({ description: 'Recherche plein texte' })
  @IsString()
  @MaxLength(100)
  @IsOptional()
  q?: string;
}

export type SortDirection = 'asc' | 'desc';

/// Traduit `?sort=champ:asc` en `orderBy` Prisma, contre une LISTE BLANCHE de
/// champs : trier sur une colonne arbitraire (ex. `passwordHash`) permettrait d'en
/// déduire le contenu par comparaisons successives. Champ absent → `fallback`.
export function parseSort<Field extends string>(
  sort: string | undefined,
  allowed: readonly Field[],
  fallback: Partial<Record<Field, SortDirection>>,
): Partial<Record<Field, SortDirection>> {
  if (!sort) return fallback;
  const [field, direction] = sort.split(':') as [Field, SortDirection];
  if (!allowed.includes(field)) {
    throw new BusinessException(
      ErrorCode.VALIDATION_FAILED,
      `Tri impossible sur « ${field} » — champs autorisés : ${allowed.join(', ')}`,
    );
  }
  return { [field]: direction } as Partial<Record<Field, SortDirection>>;
}

export class PaginationMetaDto {
  @ApiProperty() page!: number;
  @ApiProperty() limit!: number;
  @ApiProperty() total!: number;
}

/// Réponse de liste : `{ data, meta }` (CONVENTIONS.md § Pagination).
export class PaginatedDto<T> {
  data!: T[];
  @ApiProperty({ type: PaginationMetaDto }) meta!: PaginationMetaDto;
}
