import { HttpStatus, Injectable } from '@nestjs/common';
import { ActorContext, writeAudit } from '../audit/audit-writer';
import { parseApiDate } from '../common/api-date';
import { AuthenticatedUser } from '../common/auth.decorators';
import { BusinessException } from '../common/business.exception';
import { localDate } from '../common/document-number';
import { parseSort } from '../common/dto/pagination.dto';
import { ErrorCode } from '../common/error-codes';
import { assertSameMutation, runOnce } from '../common/idempotency';
import { PlanningTask, Prisma } from '../generated/prisma/client';
import { PlanningTaskStatus } from '../generated/prisma/enums';
import { PrismaService } from '../prisma/prisma.service';
import {
  CompletePlanningTaskDto,
  CreatePlanningTaskDto,
  PlanningTaskDto,
  PlanningTaskListDto,
  PlanningTaskListQueryDto,
  PlanningTaskStatusDto,
  PlanningTaskTypeDto,
  UpdatePlanningTaskDto,
} from './dto/planning.dto';

type Db = Prisma.TransactionClient;

/// Tris autorisés (liste blanche, CONVENTIONS.md).
const TASK_SORT_FIELDS = [
  'dueDate',
  'scheduledFor',
  'title',
  'completedAt',
] as const;

/// Statuts où la tâche vit encore (EN_RETARD n'en est pas un : il est CALCULÉ).
const OPEN: PlanningTaskStatus[] = ['A_FAIRE', 'EN_COURS'];

/// Planning hebdomadaire (P0 #10, spec §23).
///
/// L'ADMIN planifie ; chaque membre voit et exécute SES tâches. `EN_RETARD`
/// n'est jamais stocké : il se calcule (échéance dépassée, tâche non terminée),
/// à partir du LENDEMAIN de l'échéance — même règle que les ventes à crédit,
/// sinon une tâche due aujourd'hui passerait en retard dès 1 h à Alger.
///
/// Les transitions (démarrer, terminer, modifier, supprimer) sont des
/// COMPARE-AND-SWAP : une seule requête conditionnée par l'état attendu —
/// statut ET, pour un membre, PROPRIÉTAIRE. Deux gestes simultanés ne peuvent
/// donc pas passer tous les deux, et une tâche réassignée entre la lecture et
/// l'écriture n'est plus modifiable par l'ancien titulaire. Quand le CAS ne
/// touche rien, on relit pour dire la VRAIE raison (disparue, ou déjà close).
///
/// Journal d'audit : seuls les gestes de l'ADMIN (créer, modifier, supprimer)
/// y figurent. Démarrer et terminer sont le travail courant du membre ; ils
/// restent tracés dans la tâche elle-même (`completedAt`, `result`) sans
/// polluer la vue d'audit (spec §24, comme les ventes courantes).
@Injectable()
export class PlanningService {
  constructor(private readonly prisma: PrismaService) {}

  async create(
    dto: CreatePlanningTaskDto,
    user: AuthenticatedUser,
    actor: ActorContext,
  ): Promise<PlanningTaskDto> {
    const scheduledFor = PlanningService.day(dto.scheduledFor, 'scheduledFor');
    const dueDate = PlanningService.day(dto.dueDate, 'dueDate');
    PlanningService.assertWindow(scheduledFor, dueDate);
    PlanningService.assertNotPast(dueDate);

    // Renvoi du même formulaire (id client) : même contrat que partout
    // ailleurs (`common/idempotency.ts`) — même contenu → la tâche déjà créée ;
    // autre contenu ou autre auteur → 409 ; deux envois simultanés → le second
    // relit le premier au lieu d'un 409 générique.
    return runOnce(
      () => this.replay(dto, user),
      () => this.insert(dto, user, actor, scheduledFor, dueDate),
    );
  }

  private async replay(
    dto: CreatePlanningTaskDto,
    user: AuthenticatedUser,
  ): Promise<PlanningTaskDto | null> {
    if (!dto.id) return null;
    const existing = await this.prisma.planningTask.findUnique({
      where: { id: dto.id },
    });
    if (!existing) return null;
    const same =
      existing.title === dto.title &&
      existing.type === dto.type &&
      existing.assignedToId === dto.assignedToId &&
      PlanningService.isoDay(existing.scheduledFor) === dto.scheduledFor &&
      PlanningService.isoDay(existing.dueDate) === dto.dueDate &&
      existing.zone === (dto.zone ?? null) &&
      existing.description === (dto.description ?? null);
    assertSameMutation({ userId: existing.createdById }, user.id, same, {
      code: ErrorCode.CONFLICT,
      message: 'Cet identifiant désigne déjà une tâche au contenu différent',
    });
    return PlanningService.toDto(existing);
  }

  private async insert(
    dto: CreatePlanningTaskDto,
    user: AuthenticatedUser,
    actor: ActorContext,
    scheduledFor: Date,
    dueDate: Date,
  ): Promise<PlanningTaskDto> {
    return this.prisma.$transaction(async (tx) => {
      await PlanningService.assertAssignee(tx, dto.assignedToId);
      const task = await tx.planningTask.create({
        data: {
          id: dto.id,
          title: dto.title,
          type: dto.type,
          assignedToId: dto.assignedToId,
          createdById: user.id,
          zone: dto.zone ?? null,
          description: dto.description ?? null,
          scheduledFor,
          dueDate,
        },
      });
      await writeAudit(tx, actor, {
        action: 'CREATE',
        entityType: 'PlanningTask',
        entityId: task.id,
        newValue: PlanningService.snapshot(task),
      });
      return PlanningService.toDto(task);
    });
  }

  /// Modification par l'ADMIN tant que la tâche n'est pas terminée : une tâche
  /// close est un résultat, on ne la réécrit pas (règle 7). N'envoyer QUE les
  /// champs changés : une échéance déjà passée n'est vérifiée que si on la
  /// change, sinon une tâche en retard ne se réassignerait plus.
  async update(
    id: string,
    dto: UpdatePlanningTaskDto,
    actor: ActorContext,
  ): Promise<PlanningTaskDto> {
    return this.prisma.$transaction(async (tx) => {
      const before = await PlanningService.find(tx, id);
      const scheduledFor = dto.scheduledFor
        ? PlanningService.day(dto.scheduledFor, 'scheduledFor')
        : before.scheduledFor;
      const dueDate = dto.dueDate
        ? PlanningService.day(dto.dueDate, 'dueDate')
        : before.dueDate;
      PlanningService.assertWindow(scheduledFor, dueDate);
      if (dto.dueDate) PlanningService.assertNotPast(dueDate);
      if (dto.assignedToId) {
        await PlanningService.assertAssignee(tx, dto.assignedToId);
      }

      const changed = await tx.planningTask.updateMany({
        where: { id, status: { in: OPEN } },
        data: {
          ...(dto.title !== undefined && { title: dto.title }),
          ...(dto.type !== undefined && { type: dto.type }),
          ...(dto.assignedToId !== undefined && {
            assignedToId: dto.assignedToId,
          }),
          ...(dto.zone !== undefined && { zone: dto.zone }),
          ...(dto.description !== undefined && {
            description: dto.description,
          }),
          scheduledFor,
          dueDate,
        },
      });
      if (changed.count === 0) await PlanningService.failedTransition(tx, id);
      const after = await PlanningService.find(tx, id);
      // Un PATCH qui ne change rien n'écrit pas de trace identique avant/après.
      const oldValue = PlanningService.snapshot(before);
      const newValue = PlanningService.snapshot(after);
      if (JSON.stringify(oldValue) !== JSON.stringify(newValue)) {
        await writeAudit(tx, actor, {
          action: 'UPDATE',
          entityType: 'PlanningTask',
          entityId: id,
          oldValue,
          newValue,
        });
      }
      return PlanningService.toDto(after);
    });
  }

  /// Suppression d'une tâche créée par erreur — seulement tant que personne
  /// n'a commencé : une tâche entamée ou close a une histoire à garder.
  async remove(id: string, actor: ActorContext): Promise<void> {
    await this.prisma.$transaction(async (tx) => {
      const before = await PlanningService.find(tx, id);
      const removed = await tx.planningTask.deleteMany({
        where: { id, status: 'A_FAIRE' },
      });
      if (removed.count === 0) {
        const now = await tx.planningTask.findUnique({ where: { id } });
        if (!now) throw PlanningService.notFound();
        throw new BusinessException(
          ErrorCode.INVALID_STATE_TRANSITION,
          'Tâche déjà commencée : elle ne se supprime plus, modifiez-la',
          HttpStatus.CONFLICT,
        );
      }
      await writeAudit(tx, actor, {
        action: 'CANCEL',
        entityType: 'PlanningTask',
        entityId: id,
        oldValue: PlanningService.snapshot(before),
      });
    });
  }

  /// A_FAIRE → EN_COURS, par le membre assigné (ou l'admin). Renvoyé sur une
  /// tâche déjà en cours, il rend l'état atteint.
  async start(
    id: string,
    user: AuthenticatedUser,
    actor: ActorContext,
  ): Promise<PlanningTaskDto> {
    return this.prisma.$transaction(async (tx) => {
      const before = await this.visible(tx, id, user);
      if (before.status === 'EN_COURS') return PlanningService.toDto(before);
      const changed = await tx.planningTask.updateMany({
        where: { id, status: 'A_FAIRE', ...PlanningService.owner(user) },
        data: { status: 'EN_COURS' },
      });
      if (changed.count === 0) {
        await PlanningService.failedTransition(tx, id, user);
      }
      const after = await PlanningService.find(tx, id);
      await PlanningService.auditOnBehalf(tx, actor, user, before, after);
      return PlanningService.toDto(after);
    });
  }

  /// → TERMINEE avec son résultat, par le membre assigné (ou l'admin). On peut
  /// terminer sans avoir « démarré » : une tâche de cinq minutes n'a pas besoin
  /// de deux clics.
  async complete(
    id: string,
    dto: CompletePlanningTaskDto,
    user: AuthenticatedUser,
    actor: ActorContext,
  ): Promise<PlanningTaskDto> {
    return this.prisma.$transaction(async (tx) => {
      const before = await this.visible(tx, id, user);
      const changed = await tx.planningTask.updateMany({
        where: { id, status: { in: OPEN }, ...PlanningService.owner(user) },
        data: {
          status: 'TERMINEE',
          completedAt: new Date(),
          result: dto.result,
          comment: dto.comment ?? null,
        },
      });
      if (changed.count === 0) {
        await PlanningService.failedTransition(tx, id, user);
      }
      const after = await PlanningService.find(tx, id);
      await PlanningService.auditOnBehalf(tx, actor, user, before, after);
      return PlanningService.toDto(after);
    });
  }

  /// Le travail courant d'un membre sur SA tâche reste hors de l'audit. Mais
  /// quand l'ADMIN démarre ou termine la tâche d'un AUTRE, c'est un geste de
  /// l'admin : sans cette trace, son résultat passerait pour celui du membre
  /// (audit sécurité du 2026-09-21).
  private static async auditOnBehalf(
    tx: Db,
    actor: ActorContext,
    user: AuthenticatedUser,
    before: PlanningTask,
    after: PlanningTask,
  ): Promise<void> {
    if (before.assignedToId === user.id) return;
    await writeAudit(tx, actor, {
      action: 'UPDATE',
      entityType: 'PlanningTask',
      entityId: after.id,
      oldValue: PlanningService.snapshot(before),
      newValue: {
        ...(PlanningService.snapshot(after) as Record<string, unknown>),
        result: after.result,
        onBehalfOf: after.assignedToId,
      },
    });
  }

  async findAll(
    query: PlanningTaskListQueryDto,
    user: AuthenticatedUser,
  ): Promise<PlanningTaskListDto> {
    if ((query.late || query.open) && query.status === 'TERMINEE') {
      throw new BusinessException(
        ErrorCode.VALIDATION_FAILED,
        'Une tâche terminée n’est ni ouverte ni en retard : filtres contradictoires',
      );
    }
    const admin = user.roles.includes('ADMIN');
    const where: Prisma.PlanningTaskWhereInput = {
      // Hors ADMIN, on ne voit JAMAIS que ses propres tâches, quoi que dise la
      // requête : le filtre `assignedToId` n'est honoré que pour l'admin.
      assignedToId: admin ? query.assignedToId : user.id,
      // Les filtres se CUMULENT (l'un n'écrase pas l'autre en silence) :
      // `status=A_FAIRE&late=true` = les tâches pas commencées ET en retard.
      status:
        query.status ?? (query.late || query.open ? { in: OPEN } : undefined),
      ...(query.late && {
        dueDate: { lt: PlanningService.startOfToday() },
      }),
    };
    const [rows, total] = await Promise.all([
      this.prisma.planningTask.findMany({
        where,
        skip: (query.page - 1) * query.limit,
        take: query.limit,
        orderBy: [
          parseSort(query.sort, TASK_SORT_FIELDS, { dueDate: 'asc' }),
          { id: 'asc' },
        ],
      }),
      this.prisma.planningTask.count({ where }),
    ]);
    return {
      data: rows.map((task) => PlanningService.toDto(task)),
      meta: { page: query.page, limit: query.limit, total },
    };
  }

  async findOne(id: string, user: AuthenticatedUser): Promise<PlanningTaskDto> {
    return PlanningService.toDto(await this.visible(this.prisma, id, user));
  }

  /// Une tâche d'autrui est INTROUVABLE pour un non-admin (404, pas 403) : on
  /// ne confirme même pas qu'elle existe.
  private async visible(
    db: Db | PrismaService,
    id: string,
    user: AuthenticatedUser,
  ): Promise<PlanningTask> {
    const task = await db.planningTask.findUnique({ where: { id } });
    if (!task || !PlanningService.isMine(task, user)) {
      throw PlanningService.notFound();
    }
    return task;
  }

  private static isMine(task: PlanningTask, user: AuthenticatedUser): boolean {
    return user.roles.includes('ADMIN') || task.assignedToId === user.id;
  }

  /// Condition de PROPRIÉTÉ ajoutée au compare-and-swap d'un membre : si
  /// l'admin a réassigné la tâche entre la lecture et l'écriture, l'ancien
  /// titulaire ne la modifie plus.
  private static owner(user: AuthenticatedUser): Prisma.PlanningTaskWhereInput {
    return user.roles.includes('ADMIN') ? {} : { assignedToId: user.id };
  }

  /// Le compare-and-swap n'a rien touché : on relit pour dire la VRAIE raison.
  /// Disparue (supprimée) ou passée à un autre → 404, comme si on ne l'avait
  /// jamais vue ; sinon elle a changé d'état → 409.
  private static async failedTransition(
    tx: Db,
    id: string,
    user?: AuthenticatedUser,
  ): Promise<never> {
    const now = await tx.planningTask.findUnique({ where: { id } });
    if (!now || (user && !PlanningService.isMine(now, user))) {
      throw PlanningService.notFound();
    }
    throw PlanningService.alreadyDone();
  }

  private static async find(
    db: Db | PrismaService,
    id: string,
  ): Promise<PlanningTask> {
    const task = await db.planningTask.findUnique({ where: { id } });
    if (!task) throw PlanningService.notFound();
    return task;
  }

  /// On ne planifie qu'un membre ACTIF : une tâche confiée à un compte
  /// désactivé ne serait vue par personne.
  private static async assertAssignee(tx: Db, userId: string): Promise<void> {
    const assignee = await tx.user.findUnique({
      where: { id: userId },
      select: { isActive: true },
    });
    if (!assignee?.isActive) {
      throw new BusinessException(
        ErrorCode.VALIDATION_FAILED,
        'assignedToId : membre introuvable ou désactivé',
        HttpStatus.UNPROCESSABLE_ENTITY,
      );
    }
  }

  /// Jour civil `AAAA-MM-JJ`, stocké à minuit — la convention des échéances de
  /// vente. Une heure n'a pas de sens pour un planning à la semaine.
  private static day(raw: string, field: string): Date {
    const date = parseApiDate(raw, field);
    if (raw.length !== 10) {
      throw new BusinessException(
        ErrorCode.VALIDATION_FAILED,
        `${field} : jour attendu au format AAAA-MM-JJ`,
        HttpStatus.BAD_REQUEST,
      );
    }
    return date;
  }

  private static assertWindow(scheduledFor: Date, dueDate: Date): void {
    if (scheduledFor > dueDate) {
      throw new BusinessException(
        ErrorCode.VALIDATION_FAILED,
        'dueDate : l’échéance ne peut pas précéder le jour prévu',
        HttpStatus.UNPROCESSABLE_ENTITY,
      );
    }
  }

  private static assertNotPast(dueDate: Date): void {
    if (dueDate < PlanningService.startOfToday()) {
      throw new BusinessException(
        ErrorCode.VALIDATION_FAILED,
        'dueDate : échéance déjà passée — aujourd’hui ou plus tard',
        HttpStatus.UNPROCESSABLE_ENTITY,
      );
    }
  }

  /// Début du jour LOCAL (Africa/Algiers), à minuit comme les échéances.
  private static startOfToday(now = new Date()): Date {
    return parseApiDate(localDate(now), 'today');
  }

  private static alreadyDone(): BusinessException {
    return new BusinessException(
      ErrorCode.INVALID_STATE_TRANSITION,
      'Tâche déjà terminée : elle ne se modifie plus',
      HttpStatus.CONFLICT,
    );
  }

  private static notFound(): BusinessException {
    return new BusinessException(
      ErrorCode.NOT_FOUND,
      'Tâche introuvable',
      HttpStatus.NOT_FOUND,
    );
  }

  private static isoDay(date: Date): string {
    return date.toISOString().slice(0, 10);
  }

  /// Trace d'audit COMPLÈTE : une tâche supprimée doit pouvoir être relue.
  private static snapshot(task: PlanningTask): Prisma.InputJsonValue {
    return {
      title: task.title,
      type: task.type,
      status: task.status,
      assignedToId: task.assignedToId,
      createdById: task.createdById,
      zone: task.zone,
      description: task.description,
      scheduledFor: PlanningService.isoDay(task.scheduledFor),
      dueDate: PlanningService.isoDay(task.dueDate),
    };
  }

  private static toDto(task: PlanningTask, now = new Date()): PlanningTaskDto {
    return {
      id: task.id,
      title: task.title,
      type: task.type as PlanningTaskTypeDto,
      status: task.status as PlanningTaskStatusDto,
      isLate:
        task.status !== 'TERMINEE' &&
        task.dueDate < PlanningService.startOfToday(now),
      assignedToId: task.assignedToId,
      createdById: task.createdById,
      zone: task.zone,
      description: task.description,
      scheduledFor: PlanningService.isoDay(task.scheduledFor),
      dueDate: PlanningService.isoDay(task.dueDate),
      completedAt: task.completedAt,
      comment: task.comment,
      result: task.result,
      updatedAt: task.updatedAt,
    };
  }
}
