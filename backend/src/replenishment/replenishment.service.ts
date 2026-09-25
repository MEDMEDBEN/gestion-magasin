import { Injectable } from '@nestjs/common';
import { formatQuantity } from '../common/quantity';
import {
  isLowStock,
  isOutOfStock,
  STOCK_BEARING_LOCATIONS,
  suggestedOrderQuantity,
} from '../common/replenishment';
import { Prisma } from '../generated/prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import {
  ReplenishmentLineDto,
  ReplenishmentListDto,
  ReplenishmentQueryDto,
} from './dto/replenishment.dto';

@Injectable()
export class ReplenishmentService {
  constructor(private readonly prisma: PrismaService) {}

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
}
