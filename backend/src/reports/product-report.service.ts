import { Injectable } from '@nestjs/common';
import { AuthenticatedUser, RoleCode } from '../common/auth.decorators';
import { formatQuantity } from '../common/quantity';
import { STOCK_BEARING_LOCATIONS } from '../common/replenishment';
import { Prisma } from '../generated/prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import {
  DemandLineDto,
  DemandQueryDto,
  DormantProductDto,
  DormantProductListDto,
  DormantQueryDto,
  ProductDemandDto,
} from './dto/product-report.dto';

/// Combien de produits au sommet de chaque classement : un écran se lit, il ne
/// se dépouille pas (spec §21 : « ne pas surcharger »).
const TOP = 10;

const daysAgo = (days: number) =>
  new Date(Date.now() - days * 24 * 60 * 60 * 1000);

@Injectable()
export class ProductReportService {
  constructor(private readonly prisma: PrismaService) {}

  /// Produits dormants (spec §20) : ceux qui ne se vendent plus.
  ///
  /// « Sans mouvement » est lu comme **sans VENTE VALIDÉE**, et c'est un choix :
  /// une réception remet un mouvement au compteur, or racheter un produit qui ne
  /// part pas est précisément le problème qu'on cherche. Faire repartir l'horloge
  /// à l'achat cacherait la chose qu'on veut voir. Les deux dates sont rendues et
  /// AFFICHÉES : « reçu hier, vendu il y a 200 jours » est ce qui explique à
  /// l'utilisateur pourquoi le produit est là.
  ///
  /// L'horloge lit `Sale`/`SaleLine` et non les mouvements de type `VENTE` : une
  /// vente ANNULÉE laisse son mouvement en place (l'annulation en pose un inverse,
  /// `RETOUR_CLIENT`), elle aurait donc sorti le produit de la liste pour rien. Et
  /// c'est le MÊME filtre que le rapport de demande — les deux moitiés de la
  /// feature devaient dire la même chose du même événement (relevé par la revue).
  ///
  /// Seuls les produits qui ONT du stock sont rendus : c'est là que de l'argent
  /// dort, et c'est ce qui rend la liste actionnable (promotion, transfert). Un
  /// dormant sans stock ne coûte rien.
  ///
  /// ponytail : parcourt le catalogue actif en mémoire, comme le tableau de bord
  /// et la liste de réapprovisionnement ; à passer en SQL agrégé si le catalogue
  /// grossit vraiment.
  async dormant(query: DormantQueryDto): Promise<DormantProductListDto> {
    const cutoff = daysAgo(query.days);

    // Les deux requêtes de tête sont BORNÉES, et c'est structurant : agréger
    // l'historique ENTIER de `StockMovement` à chaque appel était un scan complet
    // de table, et ce journal ne cesse de grossir (audit sécurité). Ici on ne
    // demande que « qui a vendu DEPUIS la date de coupure », ce qui suit l'index
    // de date ; les dates exactes ne sont lues QUE pour les produits retenus.
    const [products, soldWithin] = await Promise.all([
      this.prisma.product.findMany({
        where: { isActive: true },
        // Ordre STABLE : sans lui, deux appels peuvent rendre les lignes sans
        // prix (donc à urgence égale) dans un ordre différent, et la pagination
        // sauterait ou doublerait des lignes.
        orderBy: { sku: 'asc' },
        select: {
          id: true,
          sku: true,
          name: true,
          unit: true,
          lastPurchasePriceHt: true,
          stocks: {
            where: { location: { type: { in: [...STOCK_BEARING_LOCATIONS] } } },
            select: { quantity: true },
          },
        },
      }),
      this.prisma.$queryRaw<{ productId: string }[]>`
        SELECT DISTINCT sl."productId"
        FROM "SaleLine" sl
        JOIN "Sale" s ON s."id" = sl."saleId"
        WHERE s."status"::text = 'VALIDEE'
          AND s."soldAt" >= ${cutoff}
      `,
    ]);

    const soldRecently = new Set(soldWithin.map((row) => row.productId));

    const candidates: typeof products = [];
    for (const product of products) {
      const quantity = product.stocks.reduce(
        (sum, row) => sum.add(row.quantity),
        new Prisma.Decimal(0),
      );
      // Un dormant sans stock ne coûte rien : rien n'y dort.
      if (quantity.lessThanOrEqualTo(0)) continue;
      // Vendu dans la fenêtre : pas dormant. Jamais vendu : dormant, et c'est le
      // cas le plus net.
      if (soldRecently.has(product.id)) continue;
      candidates.push(product);
    }

    const [soldAt, movedAt] = await this.lastDates(
      candidates.map((product) => product.id),
    );

    const rows: (DormantProductDto & { value: number })[] = [];
    let totalWithPrice: number | null = null;

    for (const product of candidates) {
      const quantity = product.stocks.reduce(
        (sum, row) => sum.add(row.quantity),
        new Prisma.Decimal(0),
      );
      const lastSold = soldAt.get(product.id) ?? null;
      const unitCost = product.lastPurchasePriceHt;
      const sleeping =
        unitCost === null ? null : quantity.times(unitCost).round().toNumber();
      if (sleeping !== null) totalWithPrice = (totalWithPrice ?? 0) + sleeping;

      rows.push({
        productId: product.id,
        sku: product.sku,
        name: product.name,
        unit: product.unit,
        quantity: formatQuantity(quantity),
        lastSoldAt: ProductReportService.dateOrNull(lastSold),
        lastMovementAt: ProductReportService.dateOrNull(
          movedAt.get(product.id),
        ),
        sleepingValueHt: sleeping,
        // Le plus d'argent immobilisé d'abord : c'est ce qu'on veut débloquer.
        // Sans prix connu, on ne peut pas classer — ces lignes ferment la liste
        // plutôt que de passer devant à tort.
        value: sleeping ?? -1,
      });
    }

    // Le plus d'argent immobilisé d'abord, puis la référence : à valeur égale
    // (et toutes les lignes sans prix sont à égalité), l'ordre doit rester le
    // même d'un appel à l'autre, sinon la pagination mentirait.
    rows.sort((a, b) => b.value - a.value || a.sku.localeCompare(b.sku));

    const start = (query.page - 1) * query.limit;
    return {
      data: rows
        .slice(start, start + query.limit)
        .map(({ value: _value, ...row }) => row),
      meta: { page: query.page, limit: query.limit, total: rows.length },
      days: query.days,
      totalSleepingValueHt: totalWithPrice,
    };
  }

  /// Produits demandés (spec §20) : ce qui part, ce qu'on réclame au dépôt, et
  /// ce qu'on a réclamé SANS l'obtenir.
  ///
  /// ⚠️ Le CHIFFRE D'AFFAIRES n'est rendu qu'à l'ADMIN. Le tableau de bord
  /// (n°15) ne montre à un vendeur que SES ventes, jamais celles du magasin —
  /// un audit précédent avait fait durcir ce cloisonnement. Rendre ici le CA
  /// global par produit à tout porteur de `product.read` le contournerait.
  /// Les QUANTITÉS, elles, restent visibles : « ce qui part » est une
  /// information de rayon, et le vendeur en a besoin pour pousser le reste.
  ///
  /// Convention du tableau de bord : ce qui n'est pas permis vaut `null`, jamais
  /// zéro — un zéro se lirait comme « rien vendu ».
  async demand(
    query: DemandQueryDto,
    user: AuthenticatedUser,
  ): Promise<ProductDemandDto> {
    const seesRevenue = user.roles.includes(RoleCode.ADMIN);
    const since = daysAgo(query.days);

    const [sold, requested, unmet] = await Promise.all([
      this.prisma.saleLine.groupBy({
        by: ['productId'],
        where: { sale: { status: 'VALIDEE', soldAt: { gte: since } } },
        _sum: { quantity: true, lineTotalHt: true },
        orderBy: { _sum: { quantity: 'desc' } },
        take: TOP,
      }),
      this.prisma.transferLine.groupBy({
        by: ['productId'],
        where: {
          transfer: {
            createdAt: { gte: since },
            // Une demande refusée ou annulée n'est pas une demande servie ni à
            // servir : elle ne dit rien de ce que le magasin réclame vraiment.
            status: { notIn: ['REFUSEE', 'ANNULEE'] },
            // DEPUIS le dépôt seulement : un retour magasin -> dépôt se lirait
            // sinon comme « demandé au dépôt » (relevé par la revue).
            fromLocation: { type: 'DEPOT' },
          },
        },
        _sum: { requestedQuantity: true },
        orderBy: { _sum: { requestedQuantity: 'desc' } },
        take: TOP,
      }),
      // La demande NON servie ne se calcule pas avec `groupBy` : c'est une somme
      // de différences entre deux colonnes.
      //
      // Bornée aux transferts dont la préparation a EU LIEU : sur une demande
      // encore en attente, `preparedQuantity` vaut 0 et l'écart serait la
      // demande entière — on lirait « rupture » là où rien n'a encore été fait.
      this.prisma.$queryRaw<{ productId: string; missing: string }[]>`
        SELECT tl."productId",
               SUM(tl."requestedQuantity" - tl."preparedQuantity")::text AS "missing"
        FROM "TransferLine" tl
        JOIN "Transfer" t ON t."id" = tl."transferId"
        WHERE t."createdAt" >= ${since}
          AND t."status"::text IN ('PREPAREE', 'EN_TRANSIT', 'RECUE')
          AND tl."requestedQuantity" > tl."preparedQuantity"
        GROUP BY tl."productId"
        ORDER BY SUM(tl."requestedQuantity" - tl."preparedQuantity") DESC
        LIMIT ${TOP}
      `,
    ]);

    // Un seul aller-retour pour tous les noms des trois classements.
    const names = await this.names([
      ...sold.map((r) => r.productId),
      ...requested.map((r) => r.productId),
      ...unmet.map((r) => r.productId),
    ]);

    return {
      days: query.days,
      bestSellers: sold.flatMap((row) =>
        ProductReportService.line(
          names,
          row.productId,
          row._sum.quantity,
          seesRevenue ? row._sum.lineTotalHt : null,
        ),
      ),
      mostRequested: requested.flatMap((row) =>
        ProductReportService.line(
          names,
          row.productId,
          row._sum.requestedQuantity,
        ),
      ),
      unmetDemand: unmet.flatMap((row) =>
        ProductReportService.line(
          names,
          row.productId,
          new Prisma.Decimal(row.missing),
        ),
      ),
    };
  }

  /// Dernière vente VALIDÉE et dernier mouvement, pour une liste de produits
  /// DÉJÀ restreinte. C'est ce qui rend ces deux lectures indexables : elles
  /// portent sur quelques lignes, pas sur tout le journal.
  private async lastDates(
    ids: string[],
  ): Promise<[Map<string, Date>, Map<string, Date>]> {
    if (ids.length === 0) return [new Map(), new Map()];

    // `IN` sur des UUID : chaque paramètre est casté, sinon PostgreSQL refuse de
    // comparer une colonne `uuid` à un paramètre texte.
    const list = Prisma.join(ids.map((id) => Prisma.sql`${id}::uuid`));

    const [sales, movements] = await Promise.all([
      this.prisma.$queryRaw<{ productId: string; last: Date }[]>`
        SELECT sl."productId", MAX(s."soldAt") AS "last"
        FROM "SaleLine" sl
        JOIN "Sale" s ON s."id" = sl."saleId"
        WHERE s."status"::text = 'VALIDEE'
          AND sl."productId" IN (${list})
        GROUP BY sl."productId"
      `,
      this.prisma.stockMovement.groupBy({
        by: ['productId'],
        where: { productId: { in: ids } },
        _max: { createdAt: true },
      }),
    ]);

    return [
      new Map(sales.map((row) => [row.productId, row.last])),
      new Map(
        movements.flatMap((row) =>
          row._max.createdAt
            ? [[row.productId, row._max.createdAt] as const]
            : [],
        ),
      ),
    ];
  }

  /// Noms des produits d'un classement. PAS de filtre `isActive`, contrairement
  /// à la liste des dormants : une demande passée est un FAIT, et cacher un
  /// produit depuis désactivé donnerait un classement qui ne s'additionne plus.
  private async names(ids: string[]) {
    const products = await this.prisma.product.findMany({
      where: { id: { in: [...new Set(ids)] } },
      select: { id: true, sku: true, name: true, unit: true },
    });
    return new Map(products.map((product) => [product.id, product]));
  }

  /// Une ligne de classement. Un produit introuvable (supprimé entre-temps) est
  /// SAUTÉ plutôt que rendu avec un nom vide — d'où le `flatMap`.
  private static line(
    names: Map<string, { sku: string; name: string; unit: string }>,
    productId: string,
    quantity: Prisma.Decimal | null,
    revenueHt: number | null = null,
  ): DemandLineDto[] {
    const product = names.get(productId);
    if (!product || quantity === null) return [];
    return [
      {
        productId,
        sku: product.sku,
        name: product.name,
        unit: product.unit,
        quantity: formatQuantity(quantity),
        revenueHt,
      },
    ];
  }

  private static dateOrNull(value: Date | null | undefined): string | null {
    return value?.toISOString() ?? null;
  }
}
