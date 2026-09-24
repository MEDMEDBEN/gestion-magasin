import { HttpStatus, Injectable } from '@nestjs/common';
import { randomUUID } from 'crypto';
import { ActorContext, writeAudit } from '../audit/audit-writer';
import { AuthenticatedUser, RoleCode } from '../common/auth.decorators';
import { BusinessException } from '../common/business.exception';
import { parseSort } from '../common/dto/pagination.dto';
import { ErrorCode } from '../common/error-codes';
import { detectImageFormat } from '../common/image-format';
import { Prisma } from '../generated/prisma/client';
import { ProblemStatus } from '../generated/prisma/enums';
import { NotificationsService } from '../notifications/notifications.service';
import { PrismaService } from '../prisma/prisma.service';
import { StorageService } from '../storage/storage.service';
import {
  AssignProblemDto,
  CreateProblemDto,
  ProblemDto,
  ProblemListDto,
  ProblemListQueryDto,
  ResolveProblemDto,
} from './dto/problem.dto';

const PROBLEM_INCLUDE = {
  reportedBy: { select: { fullName: true } },
  assignedTo: { select: { fullName: true } },
  product: { select: { name: true } },
  location: { select: { name: true } },
} as const;

type ProblemRow = Prisma.ProblemGetPayload<{
  include: typeof PROBLEM_INCLUDE;
}>;

const SORT_FIELDS = ['createdAt', 'priority', 'status'] as const;

/// Signalement de problème (P1 n°18, spec §26).
///
/// Ce module NE CORRIGE RIEN : un stock faux se répare par un inventaire ou un
/// ajustement tracé (règle 2), pas en changeant un chiffre depuis un
/// signalement. Il sert à ce que le problème soit SU, attribué et clos avec une
/// explication — c'est tout, et c'est déjà beaucoup.
///
/// Machine à états : OUVERT → EN_COURS → RESOLU → FERME. On n'en saute aucune,
/// et rien ne se supprime (règle 7).
@Injectable()
export class ProblemsService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly storage: StorageService,
  ) {}

  async create(
    dto: CreateProblemDto,
    user: AuthenticatedUser,
    actor: ActorContext,
  ): Promise<ProblemDto> {
    if (dto.productId) await this.assertProduct(dto.productId);
    if (dto.locationId) await this.assertLocation(dto.locationId);

    const problem = await this.prisma.$transaction(async (tx) => {
      const created = await tx.problem.create({
        include: PROBLEM_INCLUDE,
        data: {
          id: dto.id,
          title: dto.title,
          category: dto.category,
          description: dto.description,
          priority: dto.priority ?? 'NORMALE',
          productId: dto.productId ?? null,
          locationId: dto.locationId ?? null,
          reportedById: user.id,
        },
      });
      await writeAudit(tx, actor, {
        action: 'CREATE',
        entityType: 'Problem',
        entityId: created.id,
        newValue: {
          title: created.title,
          category: created.category,
          priority: created.priority,
        },
      });
      // L'admin décide qui s'en occupe : sans alerte, un signalement attend
      // que quelqu'un pense à regarder une liste.
      await NotificationsService.notifyRoles(
        tx,
        [RoleCode.ADMIN],
        {
          type: 'PROBLEME',
          title: `Signalement : ${created.title}`,
          body: ProblemsService.categoryLabel(created.category),
          priority: created.priority,
          operationType: 'PROBLEM',
          operationId: created.id,
        },
        user.id,
      );
      return created;
    });
    return ProblemsService.toDto(problem);
  }

  /// Les signalements sont une information d'ÉQUIPE : tout le monde les voit.
  /// Rien de personnel ni d'argent — et cacher un problème à celui qui pourrait
  /// le résoudre serait absurde.
  async findAll(
    user: AuthenticatedUser,
    query: ProblemListQueryDto,
  ): Promise<ProblemListDto> {
    const where: Prisma.ProblemWhereInput = {
      ...(query.status && { status: query.status }),
      ...(query.category && { category: query.category }),
      ...(query.mine === 'true' && { reportedById: user.id }),
    };
    const [rows, total] = await Promise.all([
      this.prisma.problem.findMany({
        where,
        include: PROBLEM_INCLUDE,
        orderBy: [
          parseSort(query.sort, SORT_FIELDS, { createdAt: 'desc' }),
          { id: 'desc' },
        ],
        skip: (query.page - 1) * query.limit,
        take: query.limit,
      }),
      this.prisma.problem.count({ where }),
    ]);
    return {
      data: rows.map(ProblemsService.toDto),
      meta: { page: query.page, limit: query.limit, total },
    };
  }

  async findOne(id: string): Promise<ProblemDto> {
    return ProblemsService.toDto(await this.locate(id));
  }

  /// Attribution : l'ADMIN seul décide qui s'en occupe, et le membre désigné
  /// est prévenu — sinon personne ne sait qu'on l'attend.
  async assign(
    id: string,
    dto: AssignProblemDto,
    user: AuthenticatedUser,
    actor: ActorContext,
  ): Promise<ProblemDto> {
    const before = await this.locate(id);
    ProblemsService.assertOpen(before);
    const assignee = await this.prisma.user.findFirst({
      where: { id: dto.assignedToId, isActive: true },
      select: { id: true },
    });
    if (!assignee) {
      throw new BusinessException(
        ErrorCode.VALIDATION_FAILED,
        'assignedToId : membre introuvable ou désactivé',
        HttpStatus.UNPROCESSABLE_ENTITY,
      );
    }
    return this.transition(id, actor, user, {
      data: { assignedToId: assignee.id },
      notify: {
        userIds: [assignee.id],
        title: `Signalement à traiter : ${before.title}`,
      },
    });
  }

  /// « Je m'en occupe » : le membre assigné, ou l'admin. Prendre un
  /// signalement non attribué se l'attribue — c'est plus honnête qu'un statut
  /// EN_COURS sans responsable.
  async start(
    id: string,
    user: AuthenticatedUser,
    actor: ActorContext,
  ): Promise<ProblemDto> {
    const before = await this.locate(id);
    ProblemsService.assertOpen(before);
    ProblemsService.assertCanWork(before, user);
    if (before.status === 'EN_COURS') return ProblemsService.toDto(before);
    return this.transition(id, actor, user, {
      data: {
        status: 'EN_COURS',
        assignedToId: before.assignedToId ?? user.id,
      },
    });
  }

  /// RÉSOLU exige une explication (spec §26 : un signalement clos sans dire ce
  /// qui a été fait ne vaut rien). La colonne est nullable en base — c'est
  /// ICI que la règle tient.
  async resolve(
    id: string,
    dto: ResolveProblemDto,
    user: AuthenticatedUser,
    actor: ActorContext,
  ): Promise<ProblemDto> {
    const before = await this.locate(id);
    ProblemsService.assertOpen(before);
    ProblemsService.assertCanWork(before, user);
    return this.transition(id, actor, user, {
      data: {
        status: 'RESOLU',
        resolution: dto.resolution,
        resolvedAt: new Date(),
        assignedToId: before.assignedToId ?? user.id,
      },
      // Celui qui a signalé apprend que c'est traité : sans ça, il redemande.
      notify: {
        userIds: [before.reportedById],
        title: `Signalement résolu : ${before.title}`,
      },
    });
  }

  /// FERMER est le geste de l'ADMIN : il constate que la correction tient.
  /// On ne ferme que ce qui est RÉSOLU — sauter l'étape masquerait un problème
  /// jamais traité.
  async close(
    id: string,
    user: AuthenticatedUser,
    actor: ActorContext,
  ): Promise<ProblemDto> {
    const before = await this.locate(id);
    if (before.status === 'FERME') return ProblemsService.toDto(before);
    if (before.status !== 'RESOLU') {
      throw new BusinessException(
        ErrorCode.INVALID_STATE_TRANSITION,
        'Seul un signalement RÉSOLU se ferme : faites-le traiter d’abord',
        HttpStatus.CONFLICT,
      );
    }
    return this.transition(id, actor, user, {
      data: { status: 'FERME', closedAt: new Date() },
    });
  }

  /// Photo : l'auteur du signalement ou l'admin, tant qu'il n'est pas fermé.
  /// « Le produit est abîmé » se conteste, une photo non.
  async attachPhoto(
    id: string,
    file: Express.Multer.File,
    user: AuthenticatedUser,
    actor: ActorContext,
  ): Promise<ProblemDto> {
    const before = await this.locate(id);
    if (
      before.reportedById !== user.id &&
      !user.roles.includes(RoleCode.ADMIN)
    ) {
      throw new BusinessException(
        ErrorCode.FORBIDDEN_ROLE,
        'Photo : l’auteur du signalement ou un administrateur',
        HttpStatus.FORBIDDEN,
      );
    }
    ProblemsService.assertOpen(before);
    // Le TYPE réel est lu dans les octets, pas dans le nom ni l'en-tête envoyé :
    // un exécutable renommé « .jpg » ne devient pas une image.
    const format = file && detectImageFormat(file.buffer);
    if (!format) {
      throw new BusinessException(
        ErrorCode.VALIDATION_FAILED,
        'Photo : image JPEG, PNG ou WebP attendue',
        HttpStatus.UNPROCESSABLE_ENTITY,
      );
    }
    const key = `problems/${id}/${randomUUID()}.${format.extension}`;
    await this.storage.put(key, file.buffer, format.contentType);
    try {
      const after = await this.prisma.$transaction(async (tx) => {
        const updated = await tx.problem.update({
          where: { id },
          include: PROBLEM_INCLUDE,
          data: { photoKey: key },
        });
        await writeAudit(tx, actor, {
          action: 'UPDATE',
          entityType: 'Problem',
          entityId: id,
          oldValue: { photoKey: before.photoKey },
          newValue: { photoKey: key },
        });
        return updated;
      });
      // Remplacement : l'ancienne photo part APRÈS que la base a accepté.
      if (before.photoKey) await this.storage.remove(before.photoKey);
      return ProblemsService.toDto(after);
    } catch (error) {
      // Rien d'orphelin dans le stockage si la base a refusé.
      await this.storage.remove(key);
      throw error;
    }
  }

  /// Le stockage est privé : la photo ne sort que par cette route, derrière le
  /// même contrôle d'accès que le reste.
  async openPhoto(id: string) {
    const problem = await this.locate(id);
    if (!problem.photoKey) {
      throw new BusinessException(
        ErrorCode.NOT_FOUND,
        'Aucune photo sur ce signalement',
        HttpStatus.NOT_FOUND,
      );
    }
    return this.storage.get(problem.photoKey);
  }

  /// Toute transition passe ICI : mise à jour, audit et alerte dans la MÊME
  /// transaction. Une transition ajoutée plus tard hérite du traitement.
  private async transition(
    id: string,
    actor: ActorContext,
    user: AuthenticatedUser,
    change: {
      data: Prisma.ProblemUncheckedUpdateInput;
      notify?: { userIds: string[]; title: string };
    },
  ): Promise<ProblemDto> {
    const after = await this.prisma.$transaction(async (tx) => {
      const before = await tx.problem.findUniqueOrThrow({ where: { id } });
      const updated = await tx.problem.update({
        where: { id },
        include: PROBLEM_INCLUDE,
        data: change.data,
      });
      await writeAudit(tx, actor, {
        action: 'UPDATE',
        entityType: 'Problem',
        entityId: id,
        oldValue: { status: before.status, assignedToId: before.assignedToId },
        newValue: {
          status: updated.status,
          assignedToId: updated.assignedToId,
        },
      });
      if (change.notify) {
        await NotificationsService.notifyUsers(
          tx,
          change.notify.userIds.filter((userId) => userId !== user.id),
          {
            type: 'PROBLEME',
            title: change.notify.title,
            priority: updated.priority,
            operationType: 'PROBLEM',
            operationId: id,
          },
        );
      }
      return updated;
    });
    return ProblemsService.toDto(after);
  }

  private async locate(id: string) {
    const problem = await this.prisma.problem.findUnique({
      where: { id },
      include: PROBLEM_INCLUDE,
    });
    if (!problem) {
      throw new BusinessException(
        ErrorCode.NOT_FOUND,
        'Signalement introuvable',
        HttpStatus.NOT_FOUND,
      );
    }
    return problem;
  }

  /// Un signalement fermé ou résolu ne se retouche plus : on en ouvre un
  /// nouveau si le problème revient (règle 7 — pas de réécriture du passé).
  private static assertOpen(problem: { status: ProblemStatus }): void {
    if (problem.status === 'FERME' || problem.status === 'RESOLU') {
      throw new BusinessException(
        ErrorCode.INVALID_STATE_TRANSITION,
        'Signalement clos : rouvrez-en un nouveau si le problème persiste',
        HttpStatus.CONFLICT,
      );
    }
  }

  /// Qui travaille dessus : le membre assigné, l'admin, ou n'importe qui tant
  /// que personne n'est assigné (le premier qui s'en saisit).
  private static assertCanWork(
    problem: { assignedToId: string | null },
    user: AuthenticatedUser,
  ): void {
    if (
      problem.assignedToId &&
      problem.assignedToId !== user.id &&
      !user.roles.includes(RoleCode.ADMIN)
    ) {
      throw new BusinessException(
        ErrorCode.FORBIDDEN_ROLE,
        'Ce signalement est confié à quelqu’un d’autre',
        HttpStatus.FORBIDDEN,
      );
    }
  }

  private async assertProduct(productId: string): Promise<void> {
    const exists = await this.prisma.product.count({
      where: { id: productId },
    });
    if (!exists) {
      throw new BusinessException(
        ErrorCode.VALIDATION_FAILED,
        'productId : produit introuvable',
        HttpStatus.UNPROCESSABLE_ENTITY,
      );
    }
  }

  private async assertLocation(locationId: string): Promise<void> {
    const exists = await this.prisma.location.count({
      where: { id: locationId },
    });
    if (!exists) {
      throw new BusinessException(
        ErrorCode.VALIDATION_FAILED,
        'locationId : emplacement introuvable',
        HttpStatus.UNPROCESSABLE_ENTITY,
      );
    }
  }

  private static categoryLabel(category: string): string {
    return category.toLowerCase().replace(/_/g, ' ');
  }

  private static toDto(row: ProblemRow): ProblemDto {
    return {
      id: row.id,
      title: row.title,
      category: row.category,
      description: row.description,
      priority: row.priority,
      status: row.status,
      // La CLÉ de stockage ne sort jamais : seulement le fait qu'une photo
      // existe, et une route pour la lire avec les droits vérifiés.
      hasPhoto: row.photoKey !== null,
      productId: row.productId,
      productName: row.product?.name ?? null,
      locationId: row.locationId,
      locationName: row.location?.name ?? null,
      reportedById: row.reportedById,
      reportedByName: row.reportedBy.fullName,
      assignedToId: row.assignedToId,
      assignedToName: row.assignedTo?.fullName ?? null,
      resolution: row.resolution,
      resolvedAt: row.resolvedAt?.toISOString() ?? null,
      closedAt: row.closedAt?.toISOString() ?? null,
      createdAt: row.createdAt.toISOString(),
    };
  }
}
