import { HttpStatus, Injectable } from '@nestjs/common';
import { ActorContext, writeAudit } from '../audit/audit-writer';
import { AuthenticatedUser, RoleCode } from '../common/auth.decorators';
import { BusinessException } from '../common/business.exception';
import { parseApiDate } from '../common/api-date';
import { parseSort } from '../common/dto/pagination.dto';
import { ErrorCode } from '../common/error-codes';
import { assertSameMutation, runOnce } from '../common/idempotency';
import { formatDA } from '../common/pdf/pdf';
import { CashSession, Prisma } from '../generated/prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import {
  CashSessionDto,
  CashSessionListDto,
  CashSessionListQueryDto,
  CloseCashSessionDto,
  OpenCashSessionDto,
} from './dto/sale.dto';

type Db = Prisma.TransactionClient;

/// Sérialise l'ouverture de caisse d'un même compte : deux ouvertures
/// simultanées ne créent jamais deux sessions ouvertes.
const CASH_SESSION_LOCK = 7401;

/// Tris autorisés (liste blanche, CONVENTIONS.md).
const CASH_SESSION_SORT_FIELDS = ['openedAt', 'closedAt', 'status'] as const;

/// Caisse (CLAUDE.md règle 12) : un encaissement espèces se rattache à une
/// session OUVERTE ; la clôture compare le compté à l'attendu (rapport Z).
@Injectable()
export class CashSessionsService {
  constructor(private readonly prisma: PrismaService) {}

  async open(
    dto: OpenCashSessionDto,
    user: AuthenticatedUser,
    actor: ActorContext,
  ): Promise<CashSessionDto> {
    const replay = async () => {
      const existing = await this.prisma.cashSession.findUnique({
        where: { openMutationId: dto.clientMutationId },
      });
      if (!existing) return null;
      assertSameMutation(
        existing,
        user.id,
        existing.locationId === dto.locationId &&
          existing.openingFloat === dto.openingFloat,
        {
          code: ErrorCode.CONFLICT,
          message: 'Cette ouverture de caisse a déjà été enregistrée autrement',
        },
      );
      return this.toDto(this.prisma, existing);
    };
    return runOnce(replay, () => this.openOnce(dto, user, actor));
  }

  private openOnce(
    dto: OpenCashSessionDto,
    user: AuthenticatedUser,
    actor: ActorContext,
  ): Promise<CashSessionDto> {
    return this.prisma.$transaction(async (tx) => {
      await tx.$executeRaw`SELECT pg_advisory_xact_lock(${CASH_SESSION_LOCK}::int, hashtext(${user.id}))`;
      const already = await tx.cashSession.findFirst({
        where: { userId: user.id, status: 'OUVERTE' },
      });
      if (already) {
        throw new BusinessException(
          ErrorCode.CASH_SESSION_ALREADY_OPEN,
          'Vous avez déjà une caisse ouverte : clôturez-la avant d’en ouvrir une autre',
          HttpStatus.CONFLICT,
        );
      }
      const location = await tx.location.findUnique({
        where: { id: dto.locationId },
        select: { type: true, isActive: true },
      });
      if (location?.type !== 'MAGASIN' || !location.isActive) {
        throw new BusinessException(
          ErrorCode.VALIDATION_FAILED,
          'Une caisse s’ouvre au magasin',
          HttpStatus.UNPROCESSABLE_ENTITY,
        );
      }
      const session = await tx.cashSession.create({
        data: {
          userId: user.id,
          locationId: dto.locationId,
          openingFloat: dto.openingFloat,
          openMutationId: dto.clientMutationId,
        },
      });
      await writeAudit(tx, actor, {
        action: 'CREATE',
        entityType: 'CashSession',
        entityId: session.id,
        newValue: { openingFloat: session.openingFloat },
      });
      return this.toDto(tx, session);
    });
  }

  /// Toutes les caisses (ADMIN) : qui, quand, attendu / compté / écart. Totaux
  /// de TOUTE la page en une requête (jamais une par session).
  async findAll(query: CashSessionListQueryDto): Promise<CashSessionListDto> {
    const where: Prisma.CashSessionWhereInput = {
      ...(query.status && { status: query.status }),
      ...(query.userId && { userId: query.userId }),
      ...((query.from || query.to) && {
        openedAt: {
          ...(query.from && { gte: parseApiDate(query.from, 'from') }),
          ...(query.to && { lt: parseApiDate(query.to, 'to') }),
        },
      }),
    };
    const [rows, total] = await Promise.all([
      this.prisma.cashSession.findMany({
        where,
        include: { user: { select: { fullName: true } } },
        skip: (query.page - 1) * query.limit,
        take: query.limit,
        orderBy: [
          parseSort(query.sort, CASH_SESSION_SORT_FIELDS, { openedAt: 'desc' }),
          { id: 'desc' },
        ],
      }),
      this.prisma.cashSession.count({ where }),
    ]);
    const grouped = await this.prisma.cashMovement.groupBy({
      by: ['cashSessionId', 'type'],
      where: { cashSessionId: { in: rows.map((r) => r.id) } },
      _sum: { amount: true },
      _count: true,
    });
    const data = rows.map((row) => ({
      ...CashSessionsService.toDtoWith(
        row,
        CashSessionsService.sumTotals(
          grouped.filter((g) => g.cashSessionId === row.id),
        ),
      ),
      userFullName: row.user.fullName,
    }));
    return { data, meta: { page: query.page, limit: query.limit, total } };
  }

  /// Caisse ouverte du compte connecté, ou `null`.
  async current(user: AuthenticatedUser): Promise<CashSessionDto | null> {
    const session = await this.prisma.cashSession.findFirst({
      where: { userId: user.id, status: 'OUVERTE' },
    });
    return session ? this.toDto(this.prisma, session) : null;
  }

  async close(
    id: string,
    dto: CloseCashSessionDto,
    user: AuthenticatedUser,
    actor: ActorContext,
  ): Promise<CashSessionDto> {
    return this.prisma.$transaction(async (tx) => {
      const [locked] = await tx.$queryRaw<{ id: string }[]>`
        SELECT "id" FROM "CashSession" WHERE "id" = ${id}::uuid FOR UPDATE`;
      const session = locked
        ? await tx.cashSession.findUnique({ where: { id } })
        : null;
      CashSessionsService.assertCanSee(session, user);
      // Renvoi de la même clôture (réponse perdue) : le rapport Z déjà établi.
      if (session!.closeMutationId === dto.clientMutationId) {
        assertSameMutation(
          { userId: user.id },
          user.id,
          session!.countedAmount === dto.countedAmount,
          {
            code: ErrorCode.CONFLICT,
            message:
              'Cette clôture a déjà été enregistrée avec un autre montant',
          },
        );
        return this.toDto(tx, session!);
      }
      if (session!.status !== 'OUVERTE') {
        throw new BusinessException(
          ErrorCode.INVALID_STATE_TRANSITION,
          'Cette caisse est déjà clôturée',
          HttpStatus.CONFLICT,
        );
      }
      const totals = await CashSessionsService.totals(tx, id);
      const expected = session!.openingFloat + totals.cashIn - totals.cashOut;
      const closed = await tx.cashSession.update({
        where: { id },
        data: {
          status: 'CLOTUREE',
          closedAt: new Date(),
          expectedAmount: expected,
          countedAmount: dto.countedAmount,
          difference: dto.countedAmount - expected,
          note: dto.note ?? null,
          closeMutationId: dto.clientMutationId,
        },
      });
      await writeAudit(tx, actor, {
        action: 'VALIDATE',
        entityType: 'CashSession',
        entityId: id,
        newValue: {
          expectedAmount: expected,
          countedAmount: dto.countedAmount,
          difference: dto.countedAmount - expected,
        },
      });
      return this.toDto(tx, closed);
    });
  }

  /// Rapport Z : le vendeur ne voit que SA session, l'admin toutes.
  async report(id: string, user: AuthenticatedUser): Promise<CashSessionDto> {
    const session = await this.prisma.cashSession.findUnique({ where: { id } });
    CashSessionsService.assertCanSee(session, user);
    return this.toDto(this.prisma, session!);
  }

  private static assertCanSee(
    session: CashSession | null,
    user: AuthenticatedUser,
  ): void {
    // Une session d'autrui répond 404 comme une session absente : pas de fuite
    // de l'existence des caisses des collègues.
    if (
      !session ||
      (session.userId !== user.id && !user.roles.includes(RoleCode.ADMIN))
    ) {
      throw new BusinessException(
        ErrorCode.NOT_FOUND,
        'Session de caisse introuvable',
        HttpStatus.NOT_FOUND,
      );
    }
  }

  /// Caisse OUVERTE du compte, VERROUILLÉE jusqu'au commit de l'appelant : une
  /// clôture concurrente (qui prend le même verrou) ne peut plus « rater » un
  /// encaissement — l'un attend l'autre, et le rapport Z reste juste (règle 12).
  static async lockOpenSession(
    tx: Db,
    where: { userId?: string; id?: string; locationId?: string },
  ): Promise<CashSession | null> {
    const rows = await tx.$queryRaw<{ id: string }[]>`
      SELECT "id" FROM "CashSession"
      WHERE "status" = 'OUVERTE'
        AND (${where.userId ?? null}::uuid IS NULL OR "userId" = ${where.userId ?? null}::uuid)
        AND (${where.id ?? null}::uuid IS NULL OR "id" = ${where.id ?? null}::uuid)
        AND (${where.locationId ?? null}::uuid IS NULL OR "locationId" = ${where.locationId ?? null}::uuid)
      LIMIT 1
      FOR UPDATE`;
    if (rows.length === 0) return null;
    // Relue APRÈS le verrou : une clôture tout juste validée est vue.
    const session = await tx.cashSession.findUnique({
      where: { id: rows[0].id },
    });
    return session?.status === 'OUVERTE' ? session : null;
  }

  /// Espèces présentes dans le tiroir de la session, en ce moment.
  static async drawerAmount(
    db: Db | PrismaService,
    session: CashSession,
  ): Promise<number> {
    const totals = await CashSessionsService.totals(db, session.id);
    return session.openingFloat + totals.cashIn - totals.cashOut;
  }

  /// SEUL chemin de sortie d'espèces d'une caisse (annulation de vente,
  /// paiement fournisseur, remboursement d'un règlement contre-passé…) :
  /// une sortie ne rend JAMAIS la session négative (`CASH_INSUFFICIENT`).
  /// `session` doit avoir été obtenue par `lockOpenSession` dans la même
  /// transaction : deux sorties simultanées ne vident pas deux fois le tiroir.
  static async withdraw(
    tx: Db,
    session: CashSession,
    movement: { userId: string; amount: number; note: string; saleId?: string },
  ): Promise<void> {
    const inDrawer = await CashSessionsService.drawerAmount(tx, session);
    if (movement.amount > inDrawer) {
      throw new BusinessException(
        ErrorCode.CASH_INSUFFICIENT,
        `La caisse ne contient que ${formatDA(inDrawer)} : sortie de ${formatDA(movement.amount)} impossible`,
        HttpStatus.UNPROCESSABLE_ENTITY,
      );
    }
    await tx.cashMovement.create({
      data: {
        cashSessionId: session.id,
        userId: movement.userId,
        saleId: movement.saleId ?? null,
        type: 'SORTIE',
        amount: movement.amount,
        note: movement.note,
      },
    });
  }

  /// Entrée d'espèces hors vente (règlement, remboursement d'un paiement
  /// fournisseur contre-passé…). `session` verrouillée par `lockOpenSession`.
  static async deposit(
    tx: Db,
    session: CashSession,
    movement: { userId: string; amount: number; note: string; saleId?: string },
  ): Promise<void> {
    await tx.cashMovement.create({
      data: {
        cashSessionId: session.id,
        userId: movement.userId,
        saleId: movement.saleId ?? null,
        type: 'ENTREE',
        amount: movement.amount,
        note: movement.note,
      },
    });
  }

  /// Entrées (ventes espèces + apports) et sorties (retraits + prélèvements).
  static async totals(db: Db | PrismaService, cashSessionId: string) {
    const grouped = await db.cashMovement.groupBy({
      by: ['type'],
      where: { cashSessionId },
      _sum: { amount: true },
      _count: true,
    });
    return CashSessionsService.sumTotals(grouped);
  }

  private static sumTotals(
    grouped: {
      type: string;
      _sum: { amount: number | null };
      _count: number;
    }[],
  ) {
    const sum = (type: string) =>
      grouped.find((g) => g.type === type)?._sum.amount ?? 0;
    return {
      cashSales: sum('VENTE_ESPECES'),
      cashSalesCount:
        grouped.find((g) => g.type === 'VENTE_ESPECES')?._count ?? 0,
      cashIn: sum('VENTE_ESPECES') + sum('ENTREE'),
      cashOut: sum('SORTIE') + sum('PRELEVEMENT'),
    };
  }

  private async toDto(
    db: Db | PrismaService,
    session: CashSession,
  ): Promise<CashSessionDto> {
    return CashSessionsService.toDtoWith(
      session,
      await CashSessionsService.totals(db, session.id),
    );
  }

  private static toDtoWith(
    session: CashSession,
    totals: ReturnType<typeof CashSessionsService.sumTotals>,
  ): CashSessionDto {
    return {
      id: session.id,
      userId: session.userId,
      locationId: session.locationId,
      status: session.status,
      openingFloat: session.openingFloat,
      cashSalesAmount: totals.cashSales,
      cashSalesCount: totals.cashSalesCount,
      currentAmount: session.openingFloat + totals.cashIn - totals.cashOut,
      cashInAmount: totals.cashIn,
      cashOutAmount: totals.cashOut,
      expectedAmount: session.expectedAmount,
      countedAmount: session.countedAmount,
      difference: session.difference,
      openedAt: session.openedAt,
      closedAt: session.closedAt,
    };
  }
}
