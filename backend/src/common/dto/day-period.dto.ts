import { ApiPropertyOptional } from '@nestjs/swagger';
import { IsOptional, Matches } from 'class-validator';

/// Un JOUR, pas un instant : une heure avec fuseau rendrait les bornes
/// incohérentes. Les bornes s'appliquent par `localDayRange()`.
export const DAY_PATTERN = /^\d{4}-\d{2}-\d{2}$/;
export const DAY_MESSAGE = 'jour attendu au format AAAA-MM-JJ';

/// Filtre de période d'une liste d'historique : jours civils d'Alger, bornes
/// INCLUSES. Sans filtre, toute la liste.
export class DayPeriodQueryDto {
  @ApiPropertyOptional({
    description: 'Du (AAAA-MM-JJ, jour d’Alger), inclus.',
    example: '2026-09-01',
  })
  @Matches(DAY_PATTERN, { message: DAY_MESSAGE })
  @IsOptional()
  from?: string;

  @ApiPropertyOptional({
    description: 'Au (AAAA-MM-JJ, jour d’Alger), INCLUS.',
    example: '2026-09-30',
  })
  @Matches(DAY_PATTERN, { message: DAY_MESSAGE })
  @IsOptional()
  to?: string;
}
