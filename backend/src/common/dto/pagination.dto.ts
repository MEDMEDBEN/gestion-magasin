import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import { Type } from 'class-transformer';
import { IsInt, IsOptional, IsString, Matches, Max, Min } from 'class-validator';

/// Query de pagination commune à TOUTE liste : `?page=1&limit=50&sort=field:asc&q=...`
export class PaginationQueryDto {
  @ApiPropertyOptional({ default: 1, minimum: 1 })
  @Type(() => Number)
  @IsInt()
  @Min(1)
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
  @IsOptional()
  q?: string;
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
