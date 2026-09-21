import {
  Body,
  Controller,
  Delete,
  Get,
  HttpCode,
  HttpStatus,
  Ip,
  Param,
  Patch,
  Post,
  Query,
} from '@nestjs/common';
import {
  ApiBearerAuth,
  ApiConflictResponse,
  ApiCreatedResponse,
  ApiNoContentResponse,
  ApiOkResponse,
  ApiOperation,
  ApiTags,
} from '@nestjs/swagger';
import {
  AuthenticatedUser,
  CurrentUser,
  RequirePermissions,
  RoleCode,
  Roles,
} from '../common/auth.decorators';
import { CanonicalUuidPipe } from '../common/canonical-uuid.pipe';
import { ErrorResponseDto } from '../common/dto/error-response.dto';
import { PERMISSIONS } from '../common/permissions';
import {
  CompletePlanningTaskDto,
  CreatePlanningTaskDto,
  PlanningTaskDto,
  PlanningTaskListDto,
  PlanningTaskListQueryDto,
  UpdatePlanningTaskDto,
} from './dto/planning.dto';
import { PlanningService } from './planning.service';

const ALL_ROLES = [RoleCode.ADMIN, RoleCode.VENDEUR, RoleCode.MAGASINIER];

@ApiTags('Planning')
@ApiBearerAuth()
@Controller('planning-tasks')
export class PlanningController {
  constructor(private readonly planning: PlanningService) {}

  @Roles(...ALL_ROLES)
  @RequirePermissions(PERMISSIONS.PLANNING_TASK_READ)
  @Get()
  @ApiOperation({
    summary: 'Mes tâches / toutes les tâches selon le rôle',
    description:
      'L’ADMIN voit tout (filtre `assignedToId` pour le travail d’un membre) ; ' +
      'chaque autre membre ne voit QUE ses propres tâches. `late=true` : en ' +
      'retard (calculé, jamais stocké). `from`/`to` : la semaine affichée.',
  })
  @ApiOkResponse({ type: PlanningTaskListDto })
  findAll(
    @Query() query: PlanningTaskListQueryDto,
    @CurrentUser() user: AuthenticatedUser,
  ): Promise<PlanningTaskListDto> {
    return this.planning.findAll(query, user);
  }

  @Roles(...ALL_ROLES)
  @RequirePermissions(PERMISSIONS.PLANNING_TASK_READ)
  @Get(':id')
  @ApiOperation({
    summary: 'Détail d’une tâche (la sienne, ou toutes : admin)',
  })
  @ApiOkResponse({ type: PlanningTaskDto })
  findOne(
    @Param('id', CanonicalUuidPipe) id: string,
    @CurrentUser() user: AuthenticatedUser,
  ): Promise<PlanningTaskDto> {
    return this.planning.findOne(id, user);
  }

  @Roles(RoleCode.ADMIN)
  @RequirePermissions(PERMISSIONS.PLANNING_MANAGE)
  @Post()
  @ApiOperation({ summary: 'Crée une tâche planifiée (admin uniquement)' })
  @ApiCreatedResponse({ type: PlanningTaskDto })
  create(
    @Body() dto: CreatePlanningTaskDto,
    @CurrentUser() user: AuthenticatedUser,
    @Ip() ip: string,
  ): Promise<PlanningTaskDto> {
    return this.planning.create(dto, user, { userId: user.id, ipAddress: ip });
  }

  @Roles(RoleCode.ADMIN)
  @RequirePermissions(PERMISSIONS.PLANNING_MANAGE)
  @Patch(':id')
  @ApiOperation({
    summary: 'Modifie une tâche non terminée (admin uniquement)',
    description:
      'Réassigner, décaler, préciser. Une tâche close ne se réécrit pas.',
  })
  @ApiOkResponse({ type: PlanningTaskDto })
  @ApiConflictResponse({ type: ErrorResponseDto })
  update(
    @Param('id', CanonicalUuidPipe) id: string,
    @Body() dto: UpdatePlanningTaskDto,
    @CurrentUser() user: AuthenticatedUser,
    @Ip() ip: string,
  ): Promise<PlanningTaskDto> {
    return this.planning.update(id, dto, { userId: user.id, ipAddress: ip });
  }

  @Roles(RoleCode.ADMIN)
  @RequirePermissions(PERMISSIONS.PLANNING_MANAGE)
  @Delete(':id')
  @HttpCode(HttpStatus.NO_CONTENT)
  @ApiOperation({
    summary: 'Supprime une tâche créée par erreur (admin, tant que À FAIRE)',
  })
  @ApiNoContentResponse()
  @ApiConflictResponse({ type: ErrorResponseDto })
  remove(
    @Param('id', CanonicalUuidPipe) id: string,
    @CurrentUser() user: AuthenticatedUser,
    @Ip() ip: string,
  ): Promise<void> {
    return this.planning.remove(id, { userId: user.id, ipAddress: ip });
  }

  @Roles(...ALL_ROLES)
  @RequirePermissions(PERMISSIONS.PLANNING_TASK_READ)
  @Post(':id/start')
  @HttpCode(HttpStatus.OK)
  @ApiOperation({ summary: 'Démarre SA tâche : À FAIRE → EN COURS' })
  @ApiOkResponse({ type: PlanningTaskDto })
  @ApiConflictResponse({ type: ErrorResponseDto })
  start(
    @Param('id', CanonicalUuidPipe) id: string,
    @CurrentUser() user: AuthenticatedUser,
    @Ip() ip: string,
  ): Promise<PlanningTaskDto> {
    return this.planning.start(id, user, { userId: user.id, ipAddress: ip });
  }

  @Roles(...ALL_ROLES)
  @RequirePermissions(PERMISSIONS.PLANNING_TASK_READ)
  @Post(':id/complete')
  @HttpCode(HttpStatus.OK)
  @ApiOperation({
    summary: 'Termine SA tâche avec son résultat',
    description:
      'Possible depuis À FAIRE ou EN COURS. Le résultat est obligatoire.',
  })
  @ApiOkResponse({ type: PlanningTaskDto })
  @ApiConflictResponse({ type: ErrorResponseDto })
  complete(
    @Param('id', CanonicalUuidPipe) id: string,
    @Body() dto: CompletePlanningTaskDto,
    @CurrentUser() user: AuthenticatedUser,
    @Ip() ip: string,
  ): Promise<PlanningTaskDto> {
    return this.planning.complete(id, dto, user, {
      userId: user.id,
      ipAddress: ip,
    });
  }
}
