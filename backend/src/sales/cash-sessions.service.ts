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
    return runOnce(
      () => this.replayOpen(this.prisma, dto, user),
      () =>
        this.prisma.$transaction((tx) => this.openInTx(tx, dto, user, actor)),
    );
  }

  /// Ouverture déjà enregistrée sous cette clé (même contenu), ou `null`.
  /// Partagée avec la synchronisation : une ouverture faite en ligne dont la
  /// réponse s'est perdue est RECONNUE quand la clé revient par la file.
  async replayOpen(
    db: Db,
    dto: OpenCashSessionDto,
    user: AuthenticatedUser,
  ): Promise<CashSessionDto | null> {
    const existing = await db.cashSession.findUnique({
      where: { openMutationId: dto.clientMutationId },
    });
    if (!existing) return null;
    assertSameMutation(
      existing,
      user.id,
      existing.locationId === dto.locationId &&
        existing.openingFloat === dto.openingFloat &&
        (dto.id === undefined || existing.id === dto.id),
      {
        code: ErrorCode.CONFLICT,
        message: 'Cette ouverture de caisse a déjà été enregistrée autrement',
      },
    );
    return this.toDto(db, existing);
  }

  /// Cœur de l'ouverture, dans la transaction de l'appelant. `actor` null : la
  /// synchronisation écrit elle-même l'audit (contrat §4.4), pas de doublon.
  async openInTx(
    tx: Db,
    dto: OpenCashSessionDto,
    user: AuthenticatedUser,
    actor: ActorContext | null,
    openedAt: Date = new Date(),
  ): Promise<CashSessionDto> {
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
        id: dto.id,
        userId: user.id,
        locationId: dto.locationId,
        openingFloat: dto.openingFloat,
        openMutationId: dto.clientMutationId,
        openedAt,
      },
    });
    if (actor) {
      await writeAudit(tx, actor, {
        action: 'CREATE',
        entityType: 'CashSession',
        entityId: session.id,
        newValue: { openingFloat: session.openingFloat },
      });
    }
    return this.toDto(tx, session);
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
    return this.prisma.$transaction((tx) =>
      this.closeInTx(tx, id, dto, user, actor),
    );
  }

  /// Cœur de la clôture (rapport Z), dans la transaction de l'appelant. Un
  /// renvoi de la même clôture rend le rapport déjà établi. `actor` null : voir
  /// `openInTx`.
  async closeInTx(
    tx: Db,
    id: string,
    dto: CloseCashSessionDto,
    user: AuthenticatedUser,
    actor: ActorContext | null,
    closedAt: Date = new Date(),
  ): Promise<CashSessionDto> {
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
          message: 'Cette clôture a déjà été enregistrée avec un autre montant',
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
        closedAt,
        expectedAmount: expected,
        countedAmount: dto.countedAmount,
        difference: dto.countedAmount - expected,
        note: dto.note ?? null,
        closeMutationId: dto.clientMutationId,
      },
    });
    if (actor) {
      await writeAudit(tx, actor, {
        action: 'VALIDATE',
        entityType: 'CashSession',
        entityId: id,
        newValue: CashSessionsService.closeAudit(closed),
      });
    }
    return this.toDto(tx, closed);
  }

  /// Trace d'une clôture : attendu, compté, écart (centimes).
  static closeAudit(session: CashSession) {
    return {
      expectedAmount: session.expectedAmount,
      countedAmount: session.countedAmount,
      difference: session.difference,
    };
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

  /// Encaissement d'une VENTE en espèces : seul producteur de `VENTE_ESPECES`.
  /// Comme `withdraw` et `deposit`, il garde les écritures de caisse dans un
  /// seul module (CONVENTIONS.md, règle 1).
  static async recordCashSale(
    tx: Db,
    session: CashSession,
    sale: { userId: string; saleId: string; amount: number },
  ): Promise<void> {
    await tx.cashMovement.create({
      data: {
        cashSessionId: session.id,
        userId: sale.userId,
        saleId: sale.saleId,
        type: 'VENTE_ESPECES',
        amount: sale.amount,
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
