import { Injectable } from '@nestjs/common';
import { parseApiDate } from '../common/api-date';
import { AuthenticatedUser, RoleCode } from '../common/auth.decorators';
import { localDate, startOfLocalDay } from '../common/document-number';
import { PERMISSIONS } from '../common/permissions';
import { formatQuantity } from '../common/quantity';
import { Prisma } from '../generated/prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import { DashboardDto, DashboardLowStockDto } from './dto/dashboard.dto';

/// Accueil (spec §21) : un RÉSUMÉ, pas une base de données. Aucune écriture.
///
/// Chaque bloc n'est calculé que si le compte a la permission de l'écran
/// correspondant ; sinon il vaut `null` — l'app n'affiche rien plutôt qu'un
/// zéro, qui se lirait « aucune alerte ». Les montants restent en centimes.
@Injectable()
export class DashboardService {
  constructor(private readonly prisma: PrismaService) {}

  async summary(user: AuthenticatedUser): Promise<DashboardDto> {
    const can = (permission: string) => user.permissions.includes(permission);
    const now = new Date();
    // Deux bornes pour un même « aujourd'hui », et ce n'est pas un doublon :
    // `startOfDay` est l'INSTANT où la journée d'Alger commence (à comparer à
    // `soldAt`), `today` est minuit UTC, la forme sous laquelle les dates pures
    // (`dueDate`) sont enregistrées.
    const startOfDay = startOfLocalDay(now);
    const today = parseApiDate(localDate(now), 'jour');

    const [sales, stock, transfers, purchases, customers, suppliers, tasks] =
      await Promise.all([
        can(PERMISSIONS.SALE_CREATE) ? this.salesOfDay(user, startOfDay) : null,
        can(PERMISSIONS.STOCK_READ_STORE) ||
        can(PERMISSIONS.STOCK_READ_WAREHOUSE)
          ? this.stockAlerts()
          : null,
        can(PERMISSIONS.TRANSFER_REQUEST) ||
        can(PERMISSIONS.TRANSFER_PREPARE) ||
        can(PERMISSIONS.TRANSFER_RECEIVE)
          ? this.transfers()
          : null,
        can(PERMISSIONS.RECEPTION_CREATE) ? this.ordersToReceive() : null,
        can(PERMISSIONS.CUSTOMER_READ) ? this.customerDebt(today) : null,
        can(PERMISSIONS.SUPPLIER_READ) ? this.supplierDebt() : null,
        can(PERMISSIONS.PLANNING_TASK_READ) ? this.myTasks(user, today) : null,
      ]);

    return {
      day: localDate(now),
      sales,
      stock,
      transfers,
      purchases,
      customers,
      suppliers,
      tasks,
    };
  }

  /// Ventes VALIDÉES du jour : les miennes, ou toutes pour l'admin — le même
  /// cloisonnement que la liste des ventes et le planning.
  private async salesOfDay(user: AuthenticatedUser, startOfDay: Date) {
    const totals = await this.prisma.sale.aggregate({
      where: {
        status: 'VALIDEE',
        soldAt: { gte: startOfDay },
        ...(user.roles.includes(RoleCode.ADMIN) ? {} : { userId: user.id }),
      },
      _count: true,
      _sum: { totalTtc: true },
    });
    return { count: totals._count, revenueTtc: totals._sum.totalTtc ?? 0 };
  }

  /// Alertes de stock. La comparaison porte sur le stock RÉEL en magasin et au
  /// dépôt : les emplacements TRANSIT sont exclus, une marchandise en route
  /// n'est pas encore disponible.
  ///
  /// ponytail : parcourt le catalogue actif en mémoire (un magasin, quelques
  /// milliers de références) ; à passer en SQL agrégé si le catalogue grossit.
  private async stockAlerts() {
    const products = await this.prisma.product.findMany({
      where: { isActive: true },
      select: {
        id: true,
        name: true,
        minThreshold: true,
        stocks: {
          where: { location: { type: { in: ['MAGASIN', 'DEPOT'] } } },
          select: { quantity: true },
        },
      },
    });
    const low: (DashboardLowStockDto & { sort: number })[] = [];
    let outOfStockCount = 0;
    for (const product of products) {
      const quantity = product.stocks.reduce(
        (sum, row) => sum.add(row.quantity),
        new Prisma.Decimal(0),
      );
      if (quantity.lessThanOrEqualTo(0)) outOfStockCount++;
      if (
        product.minThreshold.greaterThan(0) &&
        quantity.lessThanOrEqualTo(product.minThreshold)
      ) {
        low.push({
          productId: product.id,
          name: product.name,
          quantity: formatQuantity(quantity),
          minThreshold: formatQuantity(product.minThreshold),
          // Ce qui manque pour repasser au-dessus du seuil : c'est l'urgence.
          sort: product.minThreshold.sub(quantity).toNumber(),
        });
      }
    }
    low.sort((a, b) => b.sort - a.sort);
    return {
      lowCount: low.length,
      outOfStockCount,
      low: low.slice(0, 5).map(({ sort: _sort, ...row }) => row),
    };
  }

  private async transfers() {
    const [toPrepare, inTransit] = await Promise.all([
      this.prisma.transfer.count({
        where: { status: { in: ['DEMANDEE', 'ACCEPTEE', 'EN_PREPARATION'] } },
      }),
      this.prisma.transfer.count({
        where: { status: { in: ['PREPAREE', 'EN_TRANSIT'] } },
      }),
    ]);
    return { toPrepare, inTransit };
  }

  /// Commandes dont il reste de la marchandise à recevoir. Une commande
  /// CLOTUREE (reliquat abandonné) n'est plus attendue.
  private async ordersToReceive() {
    return {
      toReceive: await this.prisma.purchaseOrder.count({
        where: { status: { in: ['CONFIRMEE', 'PARTIELLEMENT_RECUE'] } },
      }),
    };
  }

  /// Dette CLIENTS, même formule que la fiche client (ventes à crédit validées
  /// − encaissé − règlements), sommée en base ; `overdue` = la part dont
  /// l'échéance est passée, bornée par la dette (un acompte solde le plus
  /// ancien d'abord).
  private async customerDebt(today: Date) {
    const [sales, payments, dueSales] = await Promise.all([
      this.prisma.sale.aggregate({
        where: { status: 'VALIDEE', customerId: { not: null } },
        _sum: { totalTtc: true, paidAmount: true },
      }),
      this.prisma.customerPayment.aggregate({ _sum: { amount: true } }),
      this.prisma.sale.aggregate({
        where: {
          status: 'VALIDEE',
          customerId: { not: null },
          dueDate: { lt: today },
        },
        _sum: { totalTtc: true, paidAmount: true },
      }),
    ]);
    const paid = payments._sum.amount ?? 0;
    const debt =
      (sales._sum.totalTtc ?? 0) - (sales._sum.paidAmount ?? 0) - paid;
    const due =
      (dueSales._sum.totalTtc ?? 0) - (dueSales._sum.paidAmount ?? 0) - paid;
    return {
      debt: Math.max(debt, 0),
      overdue: Math.min(Math.max(due, 0), Math.max(debt, 0)),
    };
  }

  /// Dette FOURNISSEURS : reprise de l'existant + marchandise réellement reçue
  /// − paiements (la commande seule n'endette pas, décision 2026-09-16).
  private async supplierDebt() {
    const [opening, received, paid] = await Promise.all([
      this.prisma.supplier.aggregate({ _sum: { openingBalance: true } }),
      this.prisma.reception.aggregate({ _sum: { totalTtc: true } }),
      this.prisma.supplierPayment.aggregate({ _sum: { amount: true } }),
    ]);
    const debt =
      (opening._sum.openingBalance ?? 0) +
      (received._sum.totalTtc ?? 0) -
      (paid._sum.amount ?? 0);
    return { debt: Math.max(debt, 0) };
  }

  /// MES tâches ouvertes : l'accueil ne montre que les siennes, même à l'admin
  /// (le planning complet est son propre écran).
  private async myTasks(user: AuthenticatedUser, today: Date) {
    const mine: Prisma.PlanningTaskWhereInput = {
      assignedToId: user.id,
      status: { not: 'TERMINEE' },
    };
    const [open, late] = await Promise.all([
      this.prisma.planningTask.count({ where: mine }),
      this.prisma.planningTask.count({
        where: { ...mine, dueDate: { lt: today } },
      }),
    ]);
    return { open, late };
  }
}
