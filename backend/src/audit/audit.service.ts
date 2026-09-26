import { Injectable } from '@nestjs/common';
import { BusinessException } from '../common/business.exception';
import { startOfLocalDayOf } from '../common/document-number';
import { parseSort } from '../common/dto/pagination.dto';
import { ErrorCode } from '../common/error-codes';
import { Prisma } from '../generated/prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import {
  AuditActionDto,
  AuditLogListDto,
  AuditLogQueryDto,
} from './dto/audit.dto';

/// Tris autorisés (liste blanche, CONVENTIONS.md) : le journal se lit dans
/// l'ordre du temps, rien d'autre n'a de sens.
const AUDIT_SORT_FIELDS = ['createdAt'] as const;

/// Historique global (P0 #11, spec §24) — LECTURE SEULE.
///
/// Le journal est écrit par chaque feature, DANS la transaction de l'opération
/// tracée (`writeAudit`) ; ce service ne fait que le lire. Il n'existe aucune
/// route pour modifier ou effacer une entrée : l'historique est immuable par
/// construction (règle 7).
///
/// Les jours `from`/`to` sont des jours CIVILS à Alger : une recherche « le 21 »
/// doit couvrir le 21 d'Alger de minuit à minuit, pas de 1 h du matin à 1 h.
@Injectable()
export class AuditService {
  constructor(private readonly prisma: PrismaService) {}

  async findAll(query: AuditLogQueryDto): Promise<AuditLogListDto> {
    const from = query.from ? startOfLocalDayOf(query.from, 'from') : undefined;
    // `to` INCLUS : on s'arrête au début du lendemain.
    const until = query.to
      ? new Date(startOfLocalDayOf(query.to, 'to').getTime() + 86_400_000)
      : undefined;
    if (from && until && from >= until) {
      throw new BusinessException(
        ErrorCode.VALIDATION_FAILED,
        'Période vide : « du » doit précéder ou égaler « au »',
      );
    }
    const where: Prisma.AuditLogWhereInput = {
      ...(query.entityType && { entityType: query.entityType }),
      ...(query.entityId && { entityId: query.entityId }),
      ...(query.userId && { userId: query.userId }),
      ...(query.action && { action: query.action }),
      ...((from || until) && {
        createdAt: {
          ...(from && { gte: from }),
          ...(until && { lt: until }),
        },
      }),
    };
    const [rows, total] = await Promise.all([
      this.prisma.auditLog.findMany({
        where,
        include: { user: { select: { fullName: true } } },
        skip: (query.page - 1) * query.limit,
        take: query.limit,
        orderBy: [
          parseSort(query.sort, AUDIT_SORT_FIELDS, { createdAt: 'desc' }),
          { id: 'desc' },
        ],
      }),
      this.prisma.auditLog.count({ where }),
    ]);
    return {
      data: rows.map((row) => ({
        id: row.id,
        userId: row.userId,
        userName: row.user?.fullName ?? null,
        action: row.action as AuditActionDto,
        entityType: row.entityType,
        entityId: row.entityId,
        oldValue: AuditService.object(row.oldValue),
        newValue: AuditService.object(row.newValue),
        ipAddress: row.ipAddress,
        createdAt: row.createdAt,
      })),
      meta: { page: query.page, limit: query.limit, total },
    };
  }

  /// Les valeurs tracées sont des objets JSON ; tout autre forme (valeur
  /// scalaire d'une trace ancienne) est rendue telle quelle sous `value`.
  private static object(
    value: Prisma.JsonValue | null,
  ): Record<string, unknown> | null {
    if (value === null) return null;
    if (typeof value === 'object' && !Array.isArray(value)) {
      return value as Record<string, unknown>;
    }
    return { value };
  }
}
