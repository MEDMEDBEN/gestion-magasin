import { Body, Controller, Get, Post, Query } from '@nestjs/common';
import {
  ApiBearerAuth,
  ApiOkResponse,
  ApiOperation,
  ApiProperty,
  ApiPropertyOptional,
  ApiTags,
} from '@nestjs/swagger';
import { IsEnum, IsOptional, IsString, IsUUID, MinLength } from 'class-validator';
import { RequirePermissions, RoleCode, Roles } from '../common/auth.decorators';
import { PaginationQueryDto } from '../common/dto/pagination.dto';
import { notImplemented } from '../common/not-implemented';
import { PERMISSIONS } from '../common/permissions';

const ALL_ROLES = [RoleCode.ADMIN, RoleCode.VENDEUR, RoleCode.MAGASINIER];

export enum PlanningTaskTypeDto {
  SAISIE = 'SAISIE',
  COMPTAGE = 'COMPTAGE',
  REVISION = 'REVISION',
  RECEPTION = 'RECEPTION',
  PREPARATION = 'PREPARATION',
  AUTRE = 'AUTRE',
}

export class CreatePlanningTaskDto {
  @ApiProperty() @IsString() @MinLength(2) title!: string;
  @ApiProperty({ enum: PlanningTaskTypeDto }) @IsEnum(PlanningTaskTypeDto) type!: PlanningTaskTypeDto;
  @ApiProperty() @IsUUID() assignedToId!: string;
  @ApiProperty({ description: 'Date prévue (ISO 8601).' }) @IsString() scheduledFor!: string;
  @ApiProperty({ description: 'Échéance (ISO 8601).' }) @IsString() dueDate!: string;
  @ApiPropertyOptional() @IsUUID() @IsOptional() locationId?: string;
  @ApiPropertyOptional() @IsString() @IsOptional() zone?: string;
  @ApiPropertyOptional() @IsString() @IsOptional() description?: string;
}

export class PlanningTaskDto {
  @ApiProperty() id!: string;
  @ApiProperty() title!: string;
  @ApiProperty({ enum: PlanningTaskTypeDto }) type!: PlanningTaskTypeDto;
  @ApiProperty({ example: 'A_FAIRE', description: 'A_FAIRE → EN_COURS → TERMINEE' })
  status!: string;
  @ApiProperty({
    description: 'CALCULÉ : échéance dépassée et tâche non terminée. Jamais stocké.',
  })
  isLate!: boolean;
  @ApiProperty() dueDate!: Date;
}

export class AuditLogDto {
  @ApiProperty() id!: string;
  @ApiProperty({ nullable: true }) userId!: string | null;
  @ApiProperty({ example: 'UPDATE', description: 'CREATE | UPDATE | CANCEL | VALIDATE | ADJUST' })
  action!: string;
  @ApiProperty() entityType!: string;
  @ApiProperty() entityId!: string;
  @ApiProperty({ nullable: true }) oldValue!: Record<string, unknown> | null;
  @ApiProperty({ nullable: true }) newValue!: Record<string, unknown> | null;
  @ApiProperty() createdAt!: Date;
}

/// CONTRAT FIGÉ — implémentation avec la feature P0 n°10 « Planning ».
@ApiTags('Planning')
@ApiBearerAuth()
@Controller('planning-tasks')
export class PlanningController {
  @Roles(...ALL_ROLES)
  @RequirePermissions(PERMISSIONS.PLANNING_TASK_READ)
  @Get()
  @ApiOperation({ summary: 'Mes tâches / toutes les tâches selon le rôle' })
  @ApiOkResponse({ type: [PlanningTaskDto] })
  findAll(@Query() _query: PaginationQueryDto): Promise<PlanningTaskDto[]> {
    return notImplemented('Planning');
  }

  @Roles(RoleCode.ADMIN)
  @RequirePermissions(PERMISSIONS.PLANNING_MANAGE)
  @Post()
  @ApiOperation({ summary: 'Crée une tâche planifiée (admin uniquement)' })
  @ApiOkResponse({ type: PlanningTaskDto })
  create(@Body() _dto: CreatePlanningTaskDto): Promise<PlanningTaskDto> {
    return notImplemented('Planning');
  }
}

/// CONTRAT FIGÉ — implémentation avec la feature P0 n°11 « Historique / audit ».
@ApiTags('Audit')
@ApiBearerAuth()
@Controller('audit-logs')
export class AuditController {
  @Roles(RoleCode.ADMIN)
  @RequirePermissions(PERMISSIONS.AUDIT_READ)
  @Get()
  @ApiOperation({
    summary: 'Journal des actions sensibles (admin uniquement)',
    description:
      'Prix, ajustements, validations, annulations, permissions. ' +
      'Les ventes courantes n’y figurent pas — elles vivent dans le module Ventes.',
  })
  @ApiOkResponse({ type: [AuditLogDto] })
  findAll(@Query() _query: PaginationQueryDto): Promise<AuditLogDto[]> {
    return notImplemented('Historique / audit');
  }
}
