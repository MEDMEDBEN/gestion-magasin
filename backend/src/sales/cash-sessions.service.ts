import { HttpStatus, Injectable } from '@nestjs/common';
import { ActorContext, writeAudit } from '../audit/audit-writer';
import { AuthenticatedUser, RoleCode } from '../common/auth.decorators';
import { BusinessException } from '../common/business.exception';
import { ErrorCode } from '../common/error-codes';
import { CashSession, Prisma } from '../generated/prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import {
  CashSessionDto,
  CloseCashSessionDto,
  OpenCashSessionDto,
} from './dto/sale.dto';

type Db = Prisma.TransactionClient;

/// Sérialise l'ouverture de caisse d'un même compte : deux ouvertures
/// simultanées ne créent jamais deux sessions ouvertes.
const CASH_SESSION_LOCK = 7401;

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

  /// Entrées (ventes espèces + apports) et sorties (retraits + prélèvements).
  static async totals(db: Db | PrismaService, cashSessionId: string) {
    const grouped = await db.cashMovement.groupBy({
      by: ['type'],
      where: { cashSessionId },
      _sum: { amount: true },
      _count: true,
    });
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
    const totals = await CashSessionsService.totals(db, session.id);
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
