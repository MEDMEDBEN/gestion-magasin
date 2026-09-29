import { HttpStatus, Injectable } from '@nestjs/common';
import { ActorContext } from '../audit/audit-writer';
import { AuthenticatedUser } from '../common/auth.decorators';
import { BusinessException } from '../common/business.exception';
import { ErrorCode } from '../common/error-codes';
import { formatQuantity, parseQuantity } from '../common/quantity';
import {
  isLowStock,
  isOutOfStock,
  STOCK_BEARING_LOCATIONS,
  suggestedOrderQuantity,
} from '../common/replenishment';
import { Prisma } from '../generated/prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import { PurchaseOrdersService } from '../purchases/purchase-orders.service';
import {
  PrepareOrdersDto,
  PrepareOrdersResultDto,
  ReplenishmentLineDto,
  ReplenishmentListDto,
  ReplenishmentQueryDto,
} from './dto/replenishment.dto';

@Injectable()
export class ReplenishmentService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly purchaseOrders: PurchaseOrdersService,
  ) {}

  /// Ce qu'il faut racheter (spec §19).
  ///
  /// La règle (`stock <= seuil`), les emplacements comptés et la quantité
  /// proposée viennent de `common/replenishment.ts` — partagés avec le tableau
  /// de bord et l'alerte du journal de stock, pour que les trois ne puissent
  /// pas se contredire.
  ///
  /// ponytail : parcourt le catalogue actif en mémoire, exactement comme le
  /// tableau de bord (un magasin, quelques milliers de références) ; à passer en
  /// SQL agrégé le jour où le catalogue grossit vraiment.
  async findAll(query: ReplenishmentQueryDto): Promise<ReplenishmentListDto> {
    const products = await this.prisma.product.findMany({
      where: {
        isActive: true,
        ...(query.supplierId ? { mainSupplierId: query.supplierId } : {}),
      },
      select: {
        id: true,
        sku: true,
        name: true,
        unit: true,
        minThreshold: true,
        safetyStock: true,
        lastPurchasePriceHt: true,
        mainSupplier: { select: { id: true, name: true } },
        stocks: {
          where: { location: { type: { in: [...STOCK_BEARING_LOCATIONS] } } },
          select: { quantity: true },
        },
      },
    });

    const lines: (ReplenishmentLineDto & { urgency: number })[] = [];
    let outOfStockCount = 0;

    for (const product of products) {
      const quantity = product.stocks.reduce(
        (sum, row) => sum.add(row.quantity),
        new Prisma.Decimal(0),
      );
      // Un produit qui n'a JAMAIS eu de ligne de stock n'est pas « en
      // rupture » : il n'est simplement pas encore entré au magasin. Sans cette
      // garde, un catalogue fraîchement importé remonte ENTIER en tête de liste,
      // en urgence maximale, et la liste est inutilisable le jour de
      // l'installation (relevé par la revue du 2026-09-25).
      if (product.stocks.length === 0) continue;

      const rupture = isOutOfStock(quantity);
      if (rupture) outOfStockCount++;

      // Une rupture est à racheter même sans seuil défini : il n'y a plus rien.
      if (!rupture && !isLowStock(quantity, product.minThreshold)) continue;
      if (query.outOfStockOnly && !rupture) continue;

      const suggested = suggestedOrderQuantity(
        quantity,
        product.minThreshold,
        product.safetyStock,
      );
      lines.push({
        productId: product.id,
        sku: product.sku,
        name: product.name,
        unit: product.unit,
        quantity: formatQuantity(quantity),
        minThreshold: formatQuantity(product.minThreshold),
        safetyStock: formatQuantity(product.safetyStock),
        suggestedQuantity: formatQuantity(suggested),
        isOutOfStock: rupture,
        supplierId: product.mainSupplier?.id ?? null,
        supplierName: product.mainSupplier?.name ?? null,
        lastPurchasePriceHt: product.lastPurchasePriceHt,
        // Le plus urgent d'abord : une rupture passe devant tout, puis ce qui
        // manque le plus pour repasser au-dessus du seuil.
        urgency: rupture
          ? Number.MAX_SAFE_INTEGER
          : product.minThreshold.sub(quantity).toNumber(),
      });
    }

    lines.sort((a, b) => b.urgency - a.urgency);

    const start = (query.page - 1) * query.limit;
    return {
      data: lines
        .slice(start, start + query.limit)
        .map(({ urgency: _urgency, ...line }) => line),
      meta: { page: query.page, limit: query.limit, total: lines.length },
      outOfStockCount,
    };
  }

  /// Commandes préparées automatiquement (P2 n°22, spec §28, sans IA) : les
  /// lignes retenues sont regroupées par FOURNISSEUR PRINCIPAL et deviennent une
  /// commande BROUILLON chacune, au dernier prix d'achat connu (0 s'il n'y en a
  /// pas : à compléter). Elles passent par `PurchaseOrdersService.create` —
  /// mêmes validations, même numérotation, même audit. L'utilisateur vérifie
  /// puis l'admin confirme : rien n'est commandé ici.
  async prepareOrders(
    dto: PrepareOrdersDto,
    user: AuthenticatedUser,
    actor: ActorContext,
  ): Promise<PrepareOrdersResultDto> {
    const ids = dto.lines.map((l) => l.productId);
    if (new Set(ids).size !== ids.length) {
      throw new BusinessException(
        ErrorCode.VALIDATION_FAILED,
        'lines : un produit par ligne',
        HttpStatus.UNPROCESSABLE_ENTITY,
      );
    }
    const products = await this.prisma.product.findMany({
      where: { id: { in: ids }, isActive: true },
      select: {
        id: true,
        name: true,
        lastPurchasePriceHt: true,
        mainSupplier: { select: { id: true, name: true, isActive: true } },
      },
    });
    if (products.length !== ids.length) {
      throw new BusinessException(
        ErrorCode.VALIDATION_FAILED,
        'lines : produit introuvable ou désactivé',
        HttpStatus.UNPROCESSABLE_ENTITY,
      );
    }
    const bySupplier = new Map<
      string,
      {
        name: string;
        lines: {
          productId: string;
          orderedQuantity: string;
          unitPriceHt: number;
        }[];
      }
    >();
    const withoutSupplier: string[] = [];
    for (const line of dto.lines) {
      const product = products.find((p) => p.id === line.productId)!;
      const quantity = parseQuantity(line.quantity, 'lines.quantity');
      if (quantity.lessThanOrEqualTo(0)) {
        throw new BusinessException(
          ErrorCode.VALIDATION_FAILED,
          `Quantité invalide pour « ${product.name} »`,
          HttpStatus.UNPROCESSABLE_ENTITY,
        );
      }
      const supplier = product.mainSupplier;
      if (!supplier?.isActive) {
        withoutSupplier.push(product.name);
        continue;
      }
      const group = bySupplier.get(supplier.id) ?? {
        name: supplier.name,
        lines: [],
      };
      group.lines.push({
        productId: product.id,
        orderedQuantity: formatQuantity(quantity),
        unitPriceHt: product.lastPurchasePriceHt ?? 0,
      });
      bySupplier.set(supplier.id, group);
    }
    // Au plus 20 fournisseurs (donc 20 brouillons) par préparation.
    if (bySupplier.size > 20) {
      throw new BusinessException(
        ErrorCode.VALIDATION_FAILED,
        `${bySupplier.size} fournisseurs : préparez-en 20 au plus à la fois`,
        HttpStatus.UNPROCESSABLE_ENTITY,
      );
    }
    // ponytail: une commande après l'autre (chacune sa transaction) : un
    // fournisseur en erreur n'annule pas les brouillons déjà créés — ce ne
    // sont que des brouillons, visibles et annulables par l'admin.
    const orders: PrepareOrdersResultDto['orders'] = [];
    for (const [supplierId, group] of bySupplier) {
      const order = await this.purchaseOrders.create(
        {
          supplierId,
          lines: group.lines,
          note: 'Préparée depuis le réapprovisionnement',
        },
        user,
        actor,
      );
      orders.push({
        id: order.id,
        number: order.number,
        supplierId,
        supplierName: group.name,
        lineCount: group.lines.length,
      });
    }
    const unpricedLines = [...bySupplier.values()]
      .flatMap((g) => g.lines)
      .filter((l) => l.unitPriceHt === 0).length;
    return { orders, withoutSupplier, unpricedLines };
  }
}
