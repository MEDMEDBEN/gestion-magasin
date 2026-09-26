import { HttpStatus, Injectable } from '@nestjs/common';
import { parseApiDate } from '../common/api-date';
import { BusinessException } from '../common/business.exception';
import { localDate } from '../common/document-number';
import { ErrorCode } from '../common/error-codes';
import { formatQuantity } from '../common/quantity';
import {
  isLowStock,
  isOutOfStock,
  STOCK_BEARING_LOCATIONS,
} from '../common/replenishment';
import { Prisma } from '../generated/prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import {
  PurchasesReportDto,
  ReportPeriodDto,
  ReportPeriodQueryDto,
  SalesReportDto,
  StockReportDto,
} from './dto/business-report.dto';

const DAY_MS = 24 * 60 * 60 * 1000;

/// Un rapport sur plus de deux ans balaierait un historique que ce magasin n'a
/// pas, pour un écran que personne ne lit. La borne protège aussi la base.
const MAX_PERIOD_DAYS = 730;

interface Period {
  from: Date;
  /// Borne HAUTE EXCLUSIVE : `to` inclus côté utilisateur = lendemain à 0 h.
  toExclusive: Date;
  dto: ReportPeriodDto;
}

@Injectable()
export class BusinessReportService {
  constructor(private readonly prisma: PrismaService) {}

  /// Rapport des ventes sur une période (spec §21).
  ///
  /// Uniquement les ventes **VALIDÉES** : une vente annulée n'est pas du chiffre
  /// d'affaires, et un brouillon n'en est pas encore.
  async sales(query: ReportPeriodQueryDto): Promise<SalesReportDto> {
    const period = BusinessReportService.period(query);
    const where = {
      status: 'VALIDEE' as const,
      soldAt: { gte: period.from, lt: period.toExclusive },
    };

    const [totals, lines, byDay] = await Promise.all([
      this.prisma.sale.aggregate({
        where,
        _count: true,
        _sum: { totalHt: true, totalTax: true, totalTtc: true },
      }),
      // Les lignes portent le produit : c'est par elles que passent le coût et la
      // ventilation par catégorie.
      this.prisma.saleLine.findMany({
        where: { sale: where },
        select: {
          quantity: true,
          lineTotalHt: true,
          // La remise est portée par la LIGNE, pas par la vente : il n'existe
          // aucun champ de remise sur `Sale`.
          discountAmount: true,
          product: {
            select: {
              lastPurchasePriceHt: true,
              categoryId: true,
              category: { select: { name: true } },
            },
          },
        },
      }),
      this.prisma.$queryRaw<{ day: string; count: bigint; revenue: bigint }[]>`
        SELECT to_char("soldAt" AT TIME ZONE 'Africa/Algiers', 'YYYY-MM-DD') AS "day",
               COUNT(*) AS "count",
               COALESCE(SUM("totalHt"), 0) AS "revenue"
        FROM "Sale"
        WHERE "status"::text = 'VALIDEE'
          AND "soldAt" >= ${period.from}
          AND "soldAt" < ${period.toExclusive}
        GROUP BY 1
        ORDER BY 1
      `,
    ]);

    // Coût des marchandises vendues : quantité × DERNIER prix d'achat (règle 5).
    // Les lignes dont le produit n'a pas de coût connu sont COMPTÉES à part au
    // lieu d'être traitées comme gratuites — sinon la marge serait flatteuse.
    let cost: number | null = null;
    let discount = 0;
    const categories = new Map<
      string,
      { name: string; revenueHt: number; quantity: Prisma.Decimal }
    >();

    for (const line of lines) {
      const unitCost = line.product.lastPurchasePriceHt;
      if (unitCost !== null) {
        cost = (cost ?? 0) + line.quantity.times(unitCost).round().toNumber();
      }
      const key = line.product.categoryId ?? '';
      const bucket = categories.get(key) ?? {
        name: line.product.category?.name ?? 'Sans catégorie',
        revenueHt: 0,
        quantity: new Prisma.Decimal(0),
      };
      bucket.revenueHt += line.lineTotalHt;
      bucket.quantity = bucket.quantity.add(line.quantity);
      categories.set(key, bucket);
      discount += line.discountAmount;
    }

    const revenueHt = totals._sum.totalHt ?? 0;

    return {
      period: period.dto,
      totals: {
        count: totals._count,
        revenueHt,
        taxAmount: totals._sum.totalTax ?? 0,
        revenueTtc: totals._sum.totalTtc ?? 0,
        discountAmount: discount,
        costHt: cost,
        marginHt: cost === null ? null : revenueHt - cost,
      },
      byDay: byDay.map((row) => ({
        date: row.day,
        count: Number(row.count),
        revenueHt: Number(row.revenue),
      })),
      byCategory: [...categories.entries()]
        .map(([id, bucket]) => ({
          categoryId: id === '' ? null : id,
          categoryName: bucket.name,
          revenueHt: bucket.revenueHt,
          quantity: formatQuantity(bucket.quantity),
        }))
        .sort((a, b) => b.revenueHt - a.revenueHt),
    };
  }

  /// Rapport de stock (spec §21). SANS période : le stock est un état, pas un
  /// flux — « la valeur du stock en septembre » n'a pas de sens ici, c'est
  /// l'historique des mouvements qui le dirait.
  ///
  /// ponytail : parcourt le catalogue actif en mémoire, comme le tableau de bord
  /// et les autres rapports produits.
  async stock(): Promise<StockReportDto> {
    const products = await this.prisma.product.findMany({
      where: { isActive: true },
      select: {
        lastPurchasePriceHt: true,
        minThreshold: true,
        stocks: {
          where: { location: { type: { in: [...STOCK_BEARING_LOCATIONS] } } },
          select: {
            quantity: true,
            location: { select: { id: true, name: true, type: true } },
          },
        },
      },
    });

    const byLocation = new Map<
      string,
      {
        locationId: string;
        locationName: string;
        locationType: string;
        referenceCount: number;
        valueHt: number | null;
      }
    >();
    let total: number | null = null;
    let referenceCount = 0;
    let withoutCostCount = 0;
    let lowCount = 0;
    let outOfStockCount = 0;

    for (const product of products) {
      const quantity = product.stocks.reduce(
        (sum, row) => sum.add(row.quantity),
        new Prisma.Decimal(0),
      );
      if (isOutOfStock(quantity)) outOfStockCount++;
      if (isLowStock(quantity, product.minThreshold)) lowCount++;
      if (quantity.lessThanOrEqualTo(0)) continue;

      referenceCount++;
      const unitCost = product.lastPurchasePriceHt;
      if (unitCost === null) withoutCostCount++;

      for (const row of product.stocks) {
        if (row.quantity.lessThanOrEqualTo(0)) continue;
        const bucket = byLocation.get(row.location.id) ?? {
          locationId: row.location.id,
          locationName: row.location.name,
          locationType: row.location.type,
          referenceCount: 0,
          valueHt: null,
        };
        bucket.referenceCount++;
        if (unitCost !== null) {
          const value = row.quantity.times(unitCost).round().toNumber();
          bucket.valueHt = (bucket.valueHt ?? 0) + value;
          total = (total ?? 0) + value;
        }
        byLocation.set(row.location.id, bucket);
      }
    }

    return {
      referenceCount,
      valueHt: total,
      withoutCostCount,
      lowCount,
      outOfStockCount,
      byLocation: [...byLocation.values()].sort((a, b) =>
        a.locationName.localeCompare(b.locationName),
      ),
    };
  }

  /// Rapport des achats (spec §21).
  ///
  /// Commandé et reçu sont comptés SÉPARÉMENT et ne s'équilibrent pas : une
  /// commande de septembre peut être reçue en octobre. Les mélanger donnerait un
  /// chiffre qui ne veut rien dire.
  async purchases(query: ReportPeriodQueryDto): Promise<PurchasesReportDto> {
    const period = BusinessReportService.period(query);

    const [orders, receptions] = await Promise.all([
      this.prisma.purchaseOrder.findMany({
        where: {
          orderDate: { gte: period.from, lt: period.toExclusive },
          // Un brouillon n'est pas une commande passée, une annulée n'en est
          // plus une : ni l'un ni l'autre n'a engagé d'argent.
          status: { notIn: ['BROUILLON', 'ANNULEE'] },
        },
        select: {
          totalHt: true,
          supplierId: true,
          supplier: { select: { name: true } },
        },
      }),
      this.prisma.reception.findMany({
        where: { receivedAt: { gte: period.from, lt: period.toExclusive } },
        select: {
          supplierId: true,
          supplier: { select: { name: true } },
          // `Reception` ne porte que le TTC, et `ReceptionLine` n'a pas de
          // montant HT : il se calcule, quantité × prix unitaire réceptionné.
          lines: { select: { receivedQuantity: true, unitPriceHt: true } },
        },
      }),
    ]);

    const bySupplier = new Map<
      string,
      {
        supplierId: string;
        supplierName: string;
        orderCount: number;
        orderedHt: number;
        receivedHt: number;
      }
    >();
    const bucketOf = (id: string, name: string) => {
      const existing = bySupplier.get(id);
      if (existing) return existing;
      const created = {
        supplierId: id,
        supplierName: name,
        orderCount: 0,
        orderedHt: 0,
        receivedHt: 0,
      };
      bySupplier.set(id, created);
      return created;
    };

    let orderedHt = 0;
    for (const order of orders) {
      const bucket = bucketOf(order.supplierId, order.supplier.name);
      bucket.orderCount++;
      bucket.orderedHt += order.totalHt;
      orderedHt += order.totalHt;
    }

    let receivedHt = 0;
    for (const reception of receptions) {
      const amount = reception.lines.reduce(
        (sum, line) =>
          sum +
          line.receivedQuantity.times(line.unitPriceHt).round().toNumber(),
        0,
      );
      bucketOf(reception.supplierId, reception.supplier.name).receivedHt +=
        amount;
      receivedHt += amount;
    }

    return {
      period: period.dto,
      orderCount: orders.length,
      orderedHt,
      receivedHt,
      receptionCount: receptions.length,
      bySupplier: [...bySupplier.values()].sort(
        (a, b) => b.orderedHt - a.orderedHt,
      ),
    };
  }

  /// Période demandée, bornée et normalisée.
  ///
  /// `to` est INCLUS pour l'utilisateur : la borne interne est le lendemain à
  /// 0 h. Sans cela, « du 1er au 30 septembre » perdrait toutes les ventes du 30.
  private static period(query: ReportPeriodQueryDto): Period {
    const today = parseApiDate(localDate(new Date()), 'to');
    const to = query.to ? parseApiDate(query.to, 'to') : today;
    const from = query.from
      ? parseApiDate(query.from, 'from')
      : new Date(to.getTime() - 30 * DAY_MS);

    if (from.getTime() > to.getTime()) {
      throw new BusinessException(
        ErrorCode.VALIDATION_FAILED,
        'Période invalide : `from` est après `to`',
        HttpStatus.BAD_REQUEST,
      );
    }
    const days = Math.round((to.getTime() - from.getTime()) / DAY_MS) + 1;
    if (days > MAX_PERIOD_DAYS) {
      throw new BusinessException(
        ErrorCode.VALIDATION_FAILED,
        `Période trop longue : ${days} jours demandés, ${MAX_PERIOD_DAYS} au plus`,
        HttpStatus.BAD_REQUEST,
      );
    }

    return {
      from,
      toExclusive: new Date(to.getTime() + DAY_MS),
      dto: {
        from: from.toISOString().slice(0, 10),
        to: to.toISOString().slice(0, 10),
        days,
      },
    };
  }
}
