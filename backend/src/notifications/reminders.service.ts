import {
  Injectable,
  Logger,
  OnApplicationBootstrap,
  OnApplicationShutdown,
} from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { parseApiDate } from '../common/api-date';
import { RoleCode } from '../common/auth.decorators';
import { localDate, startOfLocalDay } from '../common/document-number';
import { formatDA } from '../common/pdf/pdf';
import { Prisma } from '../generated/prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import { SalesService } from '../sales/sales.service';
import { SuppliersService } from '../suppliers/suppliers.service';
import { NotificationsService, NotifyInput } from './notifications.service';

type Db = Prisma.TransactionClient;

/// Un balayage à la fois, même avec plusieurs instances du serveur.
const REMINDERS_LOCK = 7501;

/// Échéance « proche » : dans les 3 jours.
const SOON_DAYS = 3;

/// Garde-fou : au plus N rappels par type et par balayage (un magasin réel en
/// a quelques-uns ; au-delà, c'est une anomalie qu'on ne transforme pas en
/// avalanche de notifications).
const MAX_PER_TYPE = 200;

const DAY_MS = 86_400_000;

/// Rappels PLANIFIÉS (spec §18, P1 bis n°21j) : ce que le temps déclenche, pas
/// une opération — retard fournisseur, échéance et retard client, dette
/// fournisseur à payer, inventaire et tâches du jour, tâches en retard.
///
/// Balayage toutes les heures (et au démarrage), IDEMPOTENT : au plus UN
/// rappel par objet, par type et par jour local — relancer ne double rien.
/// ponytail : minuteur en mémoire, sans file de tâches ; si le serveur est
/// arrêté, le balayage suivant rattrape (il lit l'état, pas des événements).
@Injectable()
export class RemindersService
  implements OnApplicationBootstrap, OnApplicationShutdown
{
  private readonly logger = new Logger(RemindersService.name);
  private timer?: NodeJS.Timeout;

  constructor(
    private readonly prisma: PrismaService,
    private readonly config: ConfigService,
  ) {}

  onApplicationBootstrap(): void {
    // 0 : désactivé (tests e2e — ils appellent `sweep` eux-mêmes).
    const every = Number(
      this.config.get<string>('REMINDERS_INTERVAL_MS') ?? 3_600_000,
    );
    if (!Number.isFinite(every) || every <= 0) return;
    const run = () =>
      this.sweep().catch((error: unknown) =>
        this.logger.error('Balayage des rappels en échec', error as Error),
      );
    void run();
    this.timer = setInterval(run, every);
    this.timer.unref();
  }

  onApplicationShutdown(): void {
    if (this.timer) clearInterval(this.timer);
  }

  /// Un balayage complet. Rend le nombre de rappels écrits par type.
  async sweep(now = new Date()): Promise<Record<string, number>> {
    return this.prisma.$transaction(
      async (tx) => {
        await tx.$executeRaw`SELECT pg_advisory_xact_lock(${REMINDERS_LOCK}::int, 0)`;
        // Échéances enregistrées au jour (minuit UTC du jour) : comparées au
        // jour LOCAL, comme partout (`SalesService.customerOverdue`).
        const today = parseApiDate(localDate(now), 'today');
        const soon = new Date(today.getTime() + SOON_DAYS * DAY_MS);
        const tomorrow = new Date(today.getTime() + DAY_MS);
        const since = startOfLocalDay(now);
        const counts: Record<string, number> = {};
        const remind = async (
          key: { type: NotifyInput['type']; operationId: string },
          send: () => Promise<void>,
        ) => {
          counts[key.type] ??= 0;
          if (counts[key.type] >= MAX_PER_TYPE) return;
          const already = await tx.notification.findFirst({
            where: {
              type: key.type,
              operationId: key.operationId,
              createdAt: { gte: since },
            },
            select: { id: true },
          });
          if (already) return;
          await send();
          counts[key.type] += 1;
        };

        await this.supplierReminders(tx, today, soon, remind);
        await this.customerReminders(tx, today, soon, remind);
        await this.planningReminders(tx, today, tomorrow, remind);
        return counts;
      },
      { timeout: 60_000 },
    );
  }

  private async supplierReminders(
    tx: Db,
    today: Date,
    soon: Date,
    remind: Remind,
  ): Promise<void> {
    // Livraison attendue et dépassée, commande engagée non soldée.
    const late = await tx.purchaseOrder.findMany({
      where: {
        status: { in: ['CONFIRMEE', 'PARTIELLEMENT_RECUE'] },
        expectedDate: { lt: today },
      },
      include: { supplier: { select: { name: true } } },
      orderBy: { expectedDate: 'asc' },
      take: MAX_PER_TYPE,
    });
    for (const order of late) {
      await remind({ type: 'RETARD_FOURNISSEUR', operationId: order.id }, () =>
        NotificationsService.notifyRoles(
          tx,
          [RoleCode.ADMIN, RoleCode.MAGASINIER],
          {
            type: 'RETARD_FOURNISSEUR',
            priority: 'HAUTE',
            title: `Livraison en retard : ${order.number}`,
            body: `${order.supplier.name} devait livrer le ${localDate(order.expectedDate!)}.`,
            operationType: 'PURCHASE_ORDER',
            operationId: order.id,
          },
        ),
      );
    }

    // Échéance de paiement proche ou passée, fournisseur encore créancier.
    const due = await tx.purchaseOrder.findMany({
      where: {
        status: {
          in: ['CONFIRMEE', 'PARTIELLEMENT_RECUE', 'RECUE', 'CLOTUREE'],
        },
        dueDate: { lte: soon },
      },
      include: { supplier: true },
      orderBy: { dueDate: 'asc' },
      take: MAX_PER_TYPE,
    });
    for (const order of due) {
      const { balanceDue } = await SuppliersService.debt(tx, order.supplier);
      if (balanceDue <= 0) continue;
      const overdue = order.dueDate! < today;
      await remind({ type: 'DETTE_FOURNISSEUR', operationId: order.id }, () =>
        NotificationsService.notifyRoles(tx, [RoleCode.ADMIN], {
          type: 'DETTE_FOURNISSEUR',
          priority: overdue ? 'HAUTE' : 'NORMALE',
          title: `${overdue ? 'Paiement en retard' : 'À payer'} : ${order.supplier.name}`,
          body:
            `Commande ${order.number}, échéance le ${localDate(order.dueDate!)} ` +
            `— reste dû au fournisseur ${formatDA(balanceDue)}.`,
          operationType: 'PURCHASE_ORDER',
          operationId: order.id,
        }),
      );
    }
  }

  private async customerReminders(
    tx: Db,
    today: Date,
    soon: Date,
    remind: Remind,
  ): Promise<void> {
    const sales = await tx.sale.findMany({
      where: {
        status: 'VALIDEE',
        dueDate: { lte: soon },
        customerId: { not: null },
      },
      include: {
        customer: { select: { name: true } },
        payments: { select: { amount: true } },
      },
      orderBy: { dueDate: 'asc' },
      take: MAX_PER_TYPE * 2,
    });
    // Un acompte général (sans vente) solde d'abord les dettes : un client à
    // jour n'a rien à recevoir, même si une vente garde un « reste ».
    const debts = await SalesService.customerDebts(tx, [
      ...new Set(sales.map((s) => s.customerId!)),
    ]);
    for (const sale of sales) {
      const remaining =
        sale.totalTtc -
        sale.paidAmount -
        sale.payments.reduce((sum, p) => sum + p.amount, 0);
      if (remaining <= 0 || (debts.get(sale.customerId!) ?? 0) <= 0) continue;
      const overdue = sale.dueDate! < today;
      const type = overdue ? 'DETTE_CLIENT_RETARD' : 'ECHEANCE_CLIENT';
      const input: NotifyInput = {
        type,
        priority: overdue ? 'HAUTE' : 'NORMALE',
        title: `${overdue ? 'Dette en retard' : 'Échéance proche'} : ${sale.customer!.name}`,
        body:
          `Vente ${sale.invoiceNumber ?? sale.number}, échéance le ` +
          `${localDate(sale.dueDate!)} — reste ${formatDA(remaining)}.`,
        operationType: 'SALE',
        operationId: sale.id,
      };
      // L'admin, et le vendeur de la vente (il ne voit que SES ventes).
      await remind({ type, operationId: sale.id }, async () => {
        await NotificationsService.notifyRoles(tx, [RoleCode.ADMIN], input);
        await NotificationsService.notifyUsers(tx, [sale.userId], input);
      });
    }
  }

  private async planningReminders(
    tx: Db,
    today: Date,
    tomorrow: Date,
    remind: Remind,
  ): Promise<void> {
    const tasks = await tx.planningTask.findMany({
      where: {
        status: { not: 'TERMINEE' },
        OR: [
          // À faire AUJOURD'HUI (prévue pour ce jour) …
          { scheduledFor: { gte: today, lt: tomorrow }, status: 'A_FAIRE' },
          // … ou échéance dépassée.
          { dueDate: { lt: today } },
        ],
      },
      orderBy: { dueDate: 'asc' },
      take: MAX_PER_TYPE * 2,
    });
    for (const task of tasks) {
      const late = task.dueDate < today;
      const type = late
        ? 'TACHE_EN_RETARD'
        : task.type === 'COMPTAGE'
          ? 'INVENTAIRE_A_FAIRE'
          : 'TACHE_DU_JOUR';
      const input: NotifyInput = {
        type,
        priority: late ? 'HAUTE' : 'NORMALE',
        title: late
          ? `Tâche en retard : ${task.title}`
          : type === 'INVENTAIRE_A_FAIRE'
            ? `Comptage à faire aujourd’hui : ${task.title}`
            : `À faire aujourd’hui : ${task.title}`,
        body: late ? `Échéance dépassée : ${localDate(task.dueDate)}.` : null,
        operationType: 'MANUAL',
        operationId: task.id,
      };
      await remind({ type, operationId: task.id }, async () => {
        await NotificationsService.notifyUsers(tx, [task.assignedToId], input);
        // L'admin suit les retards de son équipe (spec §23).
        if (late) {
          await NotificationsService.notifyRoles(
            tx,
            [RoleCode.ADMIN],
            input,
            task.assignedToId,
          );
        }
      });
    }
  }
}

type Remind = (
  key: { type: NotifyInput['type']; operationId: string },
  send: () => Promise<void>,
) => Promise<void>;
