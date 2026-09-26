import { HttpStatus, Injectable } from '@nestjs/common';
import { parseApiDate } from '../common/api-date';
import { BusinessException } from '../common/business.exception';
import { localDate, startOfLocalDayOf } from '../common/document-number';
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

    const [totals, perProduct, byDay] = await Promise.all([
      this.prisma.sale.aggregate({
        where,
        _count: true,
        _sum: { totalHt: true, totalTax: true, totalTtc: true },
      }),
      // Une ligne PAR PRODUIT vendu, pas par ligne de vente : sur 730 jours,
      // les lignes se comptent en centaines de milliers, les produits en
      // milliers. C'est par le produit que passent le coût et la catégorie.
      this.prisma.saleLine.groupBy({
        by: ['productId'],
        where: { sale: where },
        // La remise est portée par la LIGNE : `Sale` n'a aucun champ de remise.
        _sum: { quantity: true, lineTotalHt: true, discountAmount: true },
      }),
      // `soldAt` est un TIMESTAMP SANS fuseau qui contient de l'UTC : il faut
      // d'abord le déclarer UTC, PUIS le passer à l'heure d'Alger. En une seule
      // conversion, Postgres le lit comme une heure d'Alger et décale d'une
      // heure dans le mauvais sens (une vente de 01 h 30 tombait sur la veille).
      this.prisma.$queryRaw<{ day: string; count: bigint; revenue: bigint }[]>`
        SELECT to_char(("soldAt" AT TIME ZONE 'UTC') AT TIME ZONE 'Africa/Algiers', 'YYYY-MM-DD') AS "day",
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

    const products = new Map(
      (
        await this.prisma.product.findMany({
          where: { id: { in: perProduct.map((row) => row.productId) } },
          select: {
            id: true,
            lastPurchasePriceHt: true,
            categoryId: true,
            category: { select: { name: true } },
          },
        })
      ).map((product) => [product.id, product]),
    );

    // Coût des marchandises vendues : quantité × DERNIER prix d'achat (règle 5).
    // La marge ne se calcule que sur le CA des produits dont le coût est CONNU :
    // retrancher un coût partiel d'un CA complet compterait les ventes sans coût
    // comme de la marge pure — un chiffre faux et flatteur. Le CA sans coût est
    // rendu à part pour que l'écran le dise.
    let cost: number | null = null;
    let costedRevenueHt = 0;
    let uncostedRevenueHt = 0;
    let discount = 0;
    const categories = new Map<
      string,
      { name: string; revenueHt: number; quantity: Prisma.Decimal }
    >();

    for (const row of perProduct) {
      const product = products.get(row.productId);
      const quantity = row._sum.quantity ?? new Prisma.Decimal(0);
      const revenue = row._sum.lineTotalHt ?? 0;
      const unitCost = product?.lastPurchasePriceHt ?? null;
      if (unitCost === null) {
        uncostedRevenueHt += revenue;
      } else {
        cost = (cost ?? 0) + quantity.times(unitCost).round().toNumber();
        costedRevenueHt += revenue;
      }
      const key = product?.categoryId ?? '';
      const bucket = categories.get(key) ?? {
        name: product?.category?.name ?? 'Sans catégorie',
        revenueHt: 0,
        quantity: new Prisma.Decimal(0),
      };
      bucket.revenueHt += revenue;
      bucket.quantity = bucket.quantity.add(quantity);
      categories.set(key, bucket);
      discount += row._sum.discountAmount ?? 0;
    }

    return {
      period: period.dto,
      totals: {
        count: totals._count,
        revenueHt: totals._sum.totalHt ?? 0,
        taxAmount: totals._sum.totalTax ?? 0,
        revenueTtc: totals._sum.totalTtc ?? 0,
        discountAmount: discount,
        costHt: cost,
        marginHt: cost === null ? null : costedRevenueHt - cost,
        uncostedRevenueHt,
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
  /// ponytail: ~2 lignes `Stock` par produit actif chargées en mémoire à chaque
  /// appel (quelques milliers de références pour un magasin, admin seul, bridé à
  /// 30/min) ; passer à un agrégat SQL `SUM(quantité × coût) GROUP BY
  /// emplacement` si le catalogue dépasse ~50 000 références.
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
      // Le total valorise la quantité NETTE du produit, comme le compteur de
      // références : magasin −2 (vendu d'avance) et dépôt 5 valent 3 unités, pas 5.
      if (unitCost !== null) {
        total = (total ?? 0) + quantity.times(unitCost).round().toNumber();
      }

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
          bucket.valueHt =
            (bucket.valueHt ?? 0) +
            row.quantity.times(unitCost).round().toNumber();
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
  ///
  /// ponytail: charge les lignes de réception de la période (quelques réceptions
  /// par jour, donc quelques milliers de lignes sur 730 jours) ; passer à un
  /// `$queryRaw` agrégé par fournisseur si le volume d'achats explose.
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
    const to = parseApiDate(query.to ?? localDate(new Date()), 'to');
    // 30 jours bornes INCLUSES : aujourd'hui et les 29 précédents.
    const from = query.from
      ? parseApiDate(query.from, 'from')
      : new Date(to.getTime() - 29 * DAY_MS);

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

    const day = (date: Date) => date.toISOString().slice(0, 10);
    // Les bornes sont des jours CIVILS d'Alger comparés à des horodatages
    // réels : minuit UTC serait 01 h à Alger — la vente de 00 h 30 le 1er
    // sortirait du mois, celle du 1er du mois suivant y entrerait.
    return {
      from: startOfLocalDayOf(day(from), 'from'),
      toExclusive: startOfLocalDayOf(
        day(new Date(to.getTime() + DAY_MS)),
        'to',
      ),
      dto: { from: day(from), to: day(to), days },
    };
  }
}
