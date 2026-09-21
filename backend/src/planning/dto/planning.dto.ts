import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import { Transform } from 'class-transformer';
import {
  IsBoolean,
  IsEnum,
  IsOptional,
  IsString,
  MaxLength,
  MinLength,
} from 'class-validator';
import {
  PaginationMetaDto,
  PaginationQueryDto,
} from '../../common/dto/pagination.dto';
import {
  booleanQuery,
  ClientGeneratedId,
  IsCanonicalUuid,
  IsOptionalNotNull,
} from '../../common/validation';

export enum PlanningTaskTypeDto {
  SAISIE = 'SAISIE',
  COMPTAGE = 'COMPTAGE',
  REVISION = 'REVISION',
  RECEPTION = 'RECEPTION',
  PREPARATION = 'PREPARATION',
  AUTRE = 'AUTRE',
}

export enum PlanningTaskStatusDto {
  A_FAIRE = 'A_FAIRE',
  EN_COURS = 'EN_COURS',
  TERMINEE = 'TERMINEE',
}

const trim = ({ value }: { value: unknown }) =>
  typeof value === 'string' ? value.trim() : value;
/// Texte facultatif effaçable : chaîne vide → `null`.
const trimOrNull = ({ value }: { value: unknown }) =>
  typeof value === 'string' ? value.trim() || null : value;

export class CreatePlanningTaskDto {
  @ApiPropertyOptional({ description: 'UUID généré par le client.' })
  @ClientGeneratedId()
  id?: string;

  @ApiProperty()
  @Transform(trim)
  @IsString()
  @MinLength(2)
  @MaxLength(120)
  title!: string;

  @ApiProperty({ enum: PlanningTaskTypeDto })
  @IsEnum(PlanningTaskTypeDto)
  type!: PlanningTaskTypeDto;

  @ApiProperty({ description: 'Membre qui exécute la tâche.' })
  @IsCanonicalUuid()
  assignedToId!: string;

  @ApiProperty({
    example: '2026-09-22',
    description: 'Jour prévu, AAAA-MM-JJ.',
  })
  @IsString()
  @MaxLength(10)
  scheduledFor!: string;

  @ApiProperty({
    example: '2026-09-24',
    description: 'Échéance, AAAA-MM-JJ. En retard à partir du LENDEMAIN.',
  })
  @IsString()
  @MaxLength(10)
  dueDate!: string;

  @ApiPropertyOptional()
  @Transform(trimOrNull)
  @IsString()
  @MaxLength(100)
  @IsOptional()
  zone?: string | null;

  @ApiPropertyOptional()
  @Transform(trimOrNull)
  @IsString()
  @MaxLength(1000)
  @IsOptional()
  description?: string | null;
}

/// Modification par l'ADMIN tant que la tâche n'est pas terminée. Les champs
/// obligatoires ne sont jamais `null` ; les facultatifs acceptent `null`.
export class UpdatePlanningTaskDto {
  @ApiPropertyOptional()
  @Transform(trim)
  @IsOptionalNotNull()
  @IsString()
  @MinLength(2)
  @MaxLength(120)
  title?: string;

  @ApiPropertyOptional({ enum: PlanningTaskTypeDto })
  @IsOptionalNotNull()
  @IsEnum(PlanningTaskTypeDto)
  type?: PlanningTaskTypeDto;

  @ApiPropertyOptional()
  @IsOptionalNotNull()
  @IsCanonicalUuid()
  assignedToId?: string;

  @ApiPropertyOptional({ example: '2026-09-22' })
  @IsOptionalNotNull()
  @IsString()
  @MaxLength(10)
  scheduledFor?: string;

  @ApiPropertyOptional({ example: '2026-09-24' })
  @IsOptionalNotNull()
  @IsString()
  @MaxLength(10)
  dueDate?: string;

  @ApiPropertyOptional({ nullable: true })
  @Transform(trimOrNull)
  @IsString()
  @MaxLength(100)
  @IsOptional()
  zone?: string | null;

  @ApiPropertyOptional({ nullable: true })
  @Transform(trimOrNull)
  @IsString()
  @MaxLength(1000)
  @IsOptional()
  description?: string | null;
}

export class CompletePlanningTaskDto {
  @ApiProperty({
    description:
      'Ce qui a été constaté ou fait (spec §23 : « résultat »). Obligatoire : ' +
      'une tâche close sans résultat ne dit rien à celui qui l’a planifiée.',
  })
  @Transform(trim)
  @IsString()
  @MinLength(2)
  @MaxLength(1000)
  result!: string;

  @ApiPropertyOptional()
  @Transform(trimOrNull)
  @IsString()
  @MaxLength(1000)
  @IsOptional()
  comment?: string | null;
}

export class PlanningTaskDto {
  @ApiProperty() id!: string;
  @ApiProperty() title!: string;
  @ApiProperty({ enum: PlanningTaskTypeDto }) type!: PlanningTaskTypeDto;
  @ApiProperty({
    enum: PlanningTaskStatusDto,
    description: 'A_FAIRE → EN_COURS → TERMINEE',
  })
  status!: PlanningTaskStatusDto;
  @ApiProperty({
    description:
      'CALCULÉ : échéance dépassée (à partir du lendemain) et tâche non ' +
      'terminée. Jamais stocké.',
  })
  isLate!: boolean;
  @ApiProperty() assignedToId!: string;
  @ApiProperty() createdById!: string;
  @ApiProperty({ nullable: true }) zone!: string | null;
  @ApiProperty({ nullable: true }) description!: string | null;
  @ApiProperty({ example: '2026-09-22' }) scheduledFor!: string;
  @ApiProperty({ example: '2026-09-24' }) dueDate!: string;
  @ApiProperty({ nullable: true }) completedAt!: Date | null;
  @ApiProperty({ nullable: true }) comment!: string | null;
  @ApiProperty({ nullable: true }) result!: string | null;
  @ApiProperty() updatedAt!: Date;
}

export class PlanningTaskListQueryDto extends PaginationQueryDto {
  @ApiPropertyOptional({ enum: PlanningTaskStatusDto })
  @IsEnum(PlanningTaskStatusDto)
  @IsOptional()
  status?: PlanningTaskStatusDto;

  @ApiPropertyOptional({ description: 'Seulement les tâches en retard.' })
  @Transform(booleanQuery)
  @IsBoolean()
  @IsOptional()
  late?: boolean;

  @ApiPropertyOptional({
    description:
      'ADMIN : tâches d’un membre. Ignoré pour les autres rôles, qui ne ' +
      'voient jamais que les leurs.',
  })
  @IsCanonicalUuid()
  @IsOptional()
  assignedToId?: string;

  @ApiPropertyOptional({
    description:
      'Seulement les tâches encore OUVERTES (à faire ou en cours) — la vue ' +
      'de travail : les tâches closes ne s’y accumulent pas.',
  })
  @Transform(booleanQuery)
  @IsBoolean()
  @IsOptional()
  open?: boolean;
}

export class PlanningTaskListDto {
  @ApiProperty({ type: [PlanningTaskDto] }) data!: PlanningTaskDto[];
  @ApiProperty({ type: PaginationMetaDto }) meta!: PaginationMetaDto;
}
