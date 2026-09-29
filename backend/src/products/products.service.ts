import { HttpStatus, Injectable } from '@nestjs/common';
import { ActorContext, writeAudit } from '../audit/audit-writer';
import { AuthenticatedUser, RoleCode } from '../common/auth.decorators';
import { internalBarcode, normalizeBarcode } from '../common/barcode/barcode';
import { BusinessException } from '../common/business.exception';
import { parseSort } from '../common/dto/pagination.dto';
import { ErrorCode } from '../common/error-codes';
import { PERMISSIONS } from '../common/permissions';
import { formatQuantity, parseQuantity } from '../common/quantity';
import { Prisma, Product } from '../generated/prisma/client';
import { randomUUID } from 'crypto';
import { detectImageFormat } from '../common/image-format';
import { PrismaService } from '../prisma/prisma.service';
import { StorageService } from '../storage/storage.service';
import { StockLedgerService } from '../stock/stock-ledger.service';
import { labelFor, renderLabels } from './labels';
import {
  CreateProductDto,
  LabelsDto,
  PriceChangeDto,
  ProductDto,
  ProductListDto,
  ProductListQueryDto,
  ProductUnitDto,
  UpdateProductDto,
} from './dto/product.dto';

type Db = Prisma.TransactionClient;

/// Prix de vente par tarif, embarqués dans chaque produit renvoyé (règle 13).
export const PRODUCT_INCLUDE = {
  prices: { select: { priceTierId: true, priceHt: true } },
} as const;
type ProductWithPrices = Product & {
  prices?: { priceTierId: string; priceHt: number }[];
};
type Viewer = Pick<AuthenticatedUser, 'permissions'>;

const SORTABLE_FIELDS = [
  'name',
  'sku',
  'brand',
  'createdAt',
  'updatedAt',
] as const;

/// Sérialise les écritures de produits : la référence est unique SANS la casse,
/// ce que la contrainte `sku @unique` (sensible à la casse) n'assure pas.
/// ponytail: un seul verrou pour tout le catalogue (écritures admin, rares) ;
/// passer à un index unique `lower(sku)` si le débit d'écriture augmente.
const PRODUCT_WRITE_LOCK = 7303;

/// Tentatives de génération avant d'abandonner : un code interne ne peut être
/// déjà pris que par un code fabricant saisi à la main avec le préfixe 20.
const INTERNAL_BARCODE_ATTEMPTS = 5;

/// Une impression = une réassort, pas le catalogue entier : au-delà, le rendu
/// tiendrait le serveur (images de codes-barres, PDF sur le fil principal).
const MAX_LABELS = 1_000;

@Injectable()
export class ProductsService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly ledger: StockLedgerService,
    private readonly storage: StorageService,
  ) {}

  /// Étiquettes des produits demandés, dans l'ordre demandé, chacune répétée
  /// `copies` fois (spec §8ter). Le prix imprimé est le TTC du tarif choisi,
  /// calculé comme en caisse (`taxAmount`) : ce qu'on lit en rayon est ce qu'on
  /// paie. Un produit sans prix à ce tarif n'a pas d'étiquette — plutôt un refus
  /// qui le nomme qu'une étiquette sans prix collée en rayon.
  async labels(dto: LabelsDto): Promise<Buffer> {
    const total = dto.items.reduce((sum, item) => sum + item.copies, 0);
    if (total > MAX_LABELS) {
      throw new BusinessException(
        ErrorCode.VALIDATION_FAILED,
        `Trop d’étiquettes : ${total} demandées, ${MAX_LABELS} au plus par impression`,
        HttpStatus.BAD_REQUEST,
      );
    }
    const ids = [...new Set(dto.items.map((item) => item.productId))];
    const [products, tier] = await Promise.all([
      this.prisma.product.findMany({
        where: { id: { in: ids }, isActive: true },
        include: { taxRate: true, prices: true },
      }),
      this.prisma.priceTier.findFirst({
        where: dto.priceTierId
          ? { id: dto.priceTierId, isActive: true }
          : { isDefault: true, isActive: true },
      }),
    ]);
    if (products.length !== ids.length) {
      // Le nommer : filtre « inactifs » coché, ou catalogue local en retard.
      const found = new Set(products.map((p) => p.id));
      const missing = await this.prisma.product.findMany({
        where: { id: { in: ids.filter((id) => !found.has(id)) } },
        select: { name: true },
      });
      throw new BusinessException(
        ErrorCode.VALIDATION_FAILED,
        missing.length > 0
          ? `Produit désactivé, pas d’étiquette : ${missing
              .slice(0, 5)
              .map((p) => p.name)
              .join(', ')}`
          : 'Produit introuvable dans la liste',
        HttpStatus.UNPROCESSABLE_ENTITY,
      );
    }
    if (!tier) {
      throw new BusinessException(
        ErrorCode.PRICE_NOT_DEFINED,
        'Tarif introuvable ou inactif',
        HttpStatus.UNPROCESSABLE_ENTITY,
      );
    }
    const byId = new Map(products.map((p) => [p.id, p]));
    const priceOf = (id: string) =>
      byId.get(id)!.prices.find((p) => p.priceTierId === tier.id)?.priceHt;
    const unpriced = products.filter((p) => priceOf(p.id) === undefined);
    if (unpriced.length > 0) {
      throw new BusinessException(
        ErrorCode.PRICE_NOT_DEFINED,
        `Sans prix au tarif ${tier.name} : ` +
          unpriced
            .slice(0, 5)
            .map((p) => p.name)
            .join(', ') +
          (unpriced.length > 5 ? ` et ${unpriced.length - 5} autre(s)` : ''),
        HttpStatus.UNPROCESSABLE_ENTITY,
      );
    }
    return renderLabels(
      dto.items.flatMap((item) => {
        const label = labelFor(
          byId.get(item.productId)!,
          priceOf(item.productId)!,
        );
        return Array<typeof label>(item.copies).fill(label);
      }),
      dto.format,
    );
  }

  /// Pose ou remplace la photo d'un produit. Le type est vérifié sur les OCTETS
  /// (signature du fichier), jamais sur l'extension ni l'en-tête déclaré.
  async setImage(
    id: string,
    file: { buffer: Buffer } | undefined,
    actor: ActorContext,
  ): Promise<ProductDto> {
    if (!file?.buffer?.length) {
      throw new BusinessException(
        ErrorCode.VALIDATION_FAILED,
        'Photo absente : champ multipart « image »',
      );
    }
    const format = detectImageFormat(file.buffer);
    if (!format) {
      throw new BusinessException(
        ErrorCode.VALIDATION_FAILED,
        'Photo refusée : JPEG, PNG ou WebP uniquement',
        HttpStatus.UNPROCESSABLE_ENTITY,
      );
    }
    const exists = await this.prisma.product.findUnique({
      where: { id },
      select: { id: true },
    });
    if (!exists) throw ProductsService.notFound();

    const key = `products/${id}/${randomUUID()}.${format.extension}`;
    await this.storage.put(key, file.buffer, format.contentType);
    try {
      const { product, previous } = await this.prisma.$transaction(
        async (tx) => {
          const before = await tx.product.findUniqueOrThrow({ where: { id } });
          const updated = await tx.product.update({
            where: { id },
            data: { imageUrl: key },
            include: PRODUCT_INCLUDE,
          });
          await writeAudit(tx, actor, {
            action: 'UPDATE',
            entityType: 'Product',
            entityId: id,
            oldValue: { imageKey: before.imageUrl },
            newValue: { imageKey: key },
          });
          return { product: updated, previous: before.imageUrl };
        },
      );
      if (previous) await this.storage.remove(previous);
      return ProductsService.toDto(product);
    } catch (error) {
      // Rien d'orphelin : la photo n'est gardée que si la base l'a enregistrée.
      await this.storage.remove(key);
      throw error;
    }
  }

  async removeImage(id: string, actor: ActorContext): Promise<ProductDto> {
    const { product, previous } = await this.prisma.$transaction(async (tx) => {
      const before = await tx.product.findUnique({ where: { id } });
      if (!before) throw ProductsService.notFound();
      const updated = await tx.product.update({
        where: { id },
        data: { imageUrl: null },
        include: PRODUCT_INCLUDE,
      });
      if (before.imageUrl) {
        await writeAudit(tx, actor, {
          action: 'UPDATE',
          entityType: 'Product',
          entityId: id,
          oldValue: { imageKey: before.imageUrl },
          newValue: { imageKey: null },
        });
      }
      return { product: updated, previous: before.imageUrl };
    });
    if (previous) await this.storage.remove(previous);
    return ProductsService.toDto(product);
  }

  /// Fixe le prix HT d'un produit pour un tarif (ADMIN, `price.manage`) —
  /// « modification de prix » tracée (spec §24). Le produit est « touché » pour
  /// que la descente delta du catalogue transporte le nouveau prix.
  async setPrice(
    id: string,
    dto: { priceTierId: string; priceHt: number },
    actor: ActorContext,
  ): Promise<ProductDto> {
    return this.prisma.$transaction((tx) =>
      this.setPriceInTx(tx, id, dto, actor),
    );
  }

  /// Cœur de la pose d'un prix, dans la transaction de l'appelant (route,
  /// import).
  async setPriceInTx(
    tx: Db,
    id: string,
    dto: { priceTierId: string; priceHt: number },
    actor: ActorContext,
  ): Promise<ProductDto> {
    await ProductsService.lockWrites(tx);
    const product = await tx.product.findUnique({ where: { id } });
    if (!product) throw ProductsService.notFound();
    const tier = await tx.priceTier.findFirst({
      where: { id: dto.priceTierId, isActive: true },
    });
    if (!tier) {
      throw new BusinessException(
        ErrorCode.VALIDATION_FAILED,
        'priceTierId : tarif introuvable ou inactif',
        HttpStatus.UNPROCESSABLE_ENTITY,
      );
    }
    const before = await tx.productPrice.findUnique({
      where: {
        productId_priceTierId: { productId: id, priceTierId: tier.id },
      },
    });
    await tx.productPrice.upsert({
      where: {
        productId_priceTierId: { productId: id, priceTierId: tier.id },
      },
      create: { productId: id, priceTierId: tier.id, priceHt: dto.priceHt },
      update: { priceHt: dto.priceHt },
    });
    const updated = await tx.product.update({
      where: { id },
      data: { updatedAt: new Date() },
      include: PRODUCT_INCLUDE,
    });
    await writeAudit(tx, actor, {
      action: 'UPDATE',
      entityType: 'ProductPrice',
      entityId: id,
      oldValue: { tier: tier.code, priceHt: before?.priceHt ?? null },
      newValue: { tier: tier.code, priceHt: dto.priceHt },
    });
    return ProductsService.toDto(updated);
  }

  /// Historique des prix de vente d'un produit (P1 bis n°21n), du plus récent
  /// au plus ancien (200 derniers). L'auteur est une donnée d'audit : montré à
  /// l'ADMIN seulement.
  async priceHistory(
    id: string,
    user: AuthenticatedUser,
  ): Promise<PriceChangeDto[]> {
    if (!(await this.prisma.product.findUnique({ where: { id } }))) {
      throw ProductsService.notFound();
    }
    const admin = user.roles.includes(RoleCode.ADMIN);
    const rows = await this.prisma.auditLog.findMany({
      where: { entityType: 'ProductPrice', entityId: id },
      // Id uuid v7 en second : ordre stable entre deux tarifs d'un même import.
      orderBy: [{ createdAt: 'desc' }, { id: 'desc' }],
      take: 200,
      include: admin ? { user: { select: { fullName: true } } } : undefined,
    });
    // Une entrée d'audit d'une autre forme est ignorée, jamais une erreur 500.
    return rows.flatMap((row) => {
      const before = (row.oldValue ?? {}) as { priceHt?: number | null };
      const after = (row.newValue ?? {}) as { tier?: string; priceHt?: number };
      if (typeof after.tier !== 'string' || typeof after.priceHt !== 'number') {
        return [];
      }
      return {
        at: row.createdAt,
        tier: after.tier,
        oldPriceHt: before.priceHt ?? null,
        newPriceHt: after.priceHt,
        by: admin
          ? ((row as { user?: { fullName: string } | null }).user?.fullName ??
            null)
          : null,
      };
    });
  }

  async openImage(id: string) {
    const product = await this.prisma.product.findUnique({
      where: { id },
      select: { imageUrl: true },
    });
    if (!product?.imageUrl) {
      throw new BusinessException(
        ErrorCode.NOT_FOUND,
        'Ce produit n’a pas de photo',
        HttpStatus.NOT_FOUND,
      );
    }
    return this.storage.get(product.imageUrl);
  }

  static toDto(product: ProductWithPrices): ProductDto {
    return {
      id: product.id,
      sku: product.sku,
      barcode: product.barcode,
      name: product.name,
      description: product.description,
      brand: product.brand,
      unit: product.unit as ProductUnitDto,
      categoryId: product.categoryId,
      taxRateId: product.taxRateId,
      mainSupplierId: product.mainSupplierId,
      storageLocationId: product.storageLocationId,
      minThreshold: formatQuantity(product.minThreshold),
      safetyStock: formatQuantity(product.safetyStock),
      lastPurchasePriceHt: product.lastPurchasePriceHt,
      allowBackorder: product.allowBackorder,
      isActive: product.isActive,
      imageKey: product.imageUrl,
      prices: (product.prices ?? []).map(({ priceTierId, priceHt }) => ({
        priceTierId,
        priceHt,
      })),
      updatedAt: product.updatedAt,
    };
  }

  /// Le prix d'achat initial est une condition de PRIX (marge, plancher de
  /// vente) : `price.manage`, comme les tarifs.
  static assertCanSetCost(
    dto: { purchasePriceHt?: number },
    user: AuthenticatedUser,
  ): void {
    if (
      dto.purchasePriceHt !== undefined &&
      !user.permissions.includes(PERMISSIONS.PRICE_MANAGE)
    ) {
      throw new BusinessException(
        ErrorCode.FORBIDDEN_PERMISSION,
        'Permission requise pour fixer un prix d’achat : price.manage',
        HttpStatus.FORBIDDEN,
      );
    }
  }

  /// Ce qu'un compte voit d'un produit (docs/permissions.md) : le coût d'achat
  /// exige `cost.read`, le fournisseur principal `supplier.read` — sinon `null`.
  /// Appliqué à TOUTE réponse produit, delta compris.
  static forViewer(product: ProductDto, viewer: Viewer): ProductDto {
    const can = (permission: string) => viewer.permissions.includes(permission);
    return {
      ...product,
      lastPurchasePriceHt: can(PERMISSIONS.COST_READ)
        ? product.lastPurchasePriceHt
        : null,
      mainSupplierId: can(PERMISSIONS.SUPPLIER_READ)
        ? product.mainSupplierId
        : null,
      prices: can(PERMISSIONS.PRICE_READ) ? product.prices : [],
    };
  }

  async findAll(
    query: ProductListQueryDto,
    viewer: Viewer,
  ): Promise<ProductListDto> {
    const where: Prisma.ProductWhereInput = {};
    if (!query.includeInactive) where.isActive = true;
    if (query.categoryId) {
      where.category = {
        OR: [{ id: query.categoryId }, { parentId: query.categoryId }],
      };
    }
    if (query.q) {
      where.OR = [
        { name: { contains: query.q, mode: 'insensitive' } },
        { sku: { contains: query.q, mode: 'insensitive' } },
        { brand: { contains: query.q, mode: 'insensitive' } },
        { barcode: { contains: query.q } },
      ];
    }
    const orderBy = parseSort(query.sort, SORTABLE_FIELDS, { name: 'asc' });

    const [rows, total] = await Promise.all([
      this.prisma.product.findMany({
        where,
        include: PRODUCT_INCLUDE,
        skip: (query.page - 1) * query.limit,
        take: query.limit,
        orderBy: [orderBy, { id: 'asc' }],
      }),
      this.prisma.product.count({ where }),
    ]);
    return {
      data: rows.map((row) =>
        ProductsService.forViewer(ProductsService.toDto(row), viewer),
      ),
      meta: { page: query.page, limit: query.limit, total },
    };
  }

  async findOne(id: string, viewer: Viewer): Promise<ProductDto> {
    const product = await this.prisma.product.findUnique({
      where: { id },
      include: PRODUCT_INCLUDE,
    });
    if (!product) throw ProductsService.notFound();
    return ProductsService.forViewer(ProductsService.toDto(product), viewer);
  }

  /// Chemin du scanner : recherche exacte du code lu (espaces retirés).
  async findByBarcode(raw: string, viewer: Viewer): Promise<ProductDto> {
    const product = await this.prisma.product.findUnique({
      where: { barcode: raw.trim() },
      include: PRODUCT_INCLUDE,
    });
    if (!product) throw ProductsService.notFound();
    return ProductsService.forViewer(ProductsService.toDto(product), viewer);
  }

  async create(
    dto: CreateProductDto,
    actor: ActorContext,
  ): Promise<ProductDto> {
    return this.prisma.$transaction((tx) => this.createInTx(tx, dto, actor));
  }

  /// Cœur de la création, dans la transaction de l'appelant : la route et
  /// l'import (tout ou rien) appliquent les MÊMES règles.
  async createInTx(
    tx: Db,
    dto: CreateProductDto,
    actor: ActorContext,
  ): Promise<ProductDto> {
    await ProductsService.lockWrites(tx);
    await this.assertReferences(tx, dto);
    await ProductsService.assertSkuFree(tx, dto.sku);

    let barcode: string;
    if (dto.barcode) {
      barcode = normalizeBarcode(dto.barcode);
      await ProductsService.assertBarcodeFree(tx, barcode);
    } else {
      barcode = await ProductsService.nextInternalBarcode(tx);
    }

    const product = await tx.product.create({
      include: PRODUCT_INCLUDE,
      data: {
        id: dto.id,
        sku: dto.sku,
        barcode,
        name: dto.name,
        description: dto.description ?? null,
        brand: dto.brand ?? null,
        unit: dto.unit,
        categoryId: dto.categoryId ?? null,
        taxRateId: dto.taxRateId ?? null,
        mainSupplierId: dto.mainSupplierId ?? null,
        storageLocationId: dto.storageLocationId ?? null,
        minThreshold: ProductsService.threshold(
          dto.minThreshold,
          'minThreshold',
        ),
        safetyStock: ProductsService.threshold(dto.safetyStock, 'safetyStock'),
        allowBackorder: dto.allowBackorder ?? false,
        lastPurchasePriceHt: dto.purchasePriceHt ?? null,
      },
    });
    const created = ProductsService.toDto(product);
    const initialStock = await this.applyInitialStock(
      tx,
      created.id,
      dto.initialStock ?? [],
      actor,
    );
    await writeAudit(tx, actor, {
      action: 'CREATE',
      entityType: 'Product',
      entityId: created.id,
      newValue: {
        ...(ProductsService.auditSnapshot(created) as Prisma.InputJsonObject),
        initialStock,
      },
    });
    return created;
  }

  async update(
    id: string,
    dto: UpdateProductDto,
    user: AuthenticatedUser,
    actor: ActorContext,
  ): Promise<ProductDto> {
    ProductsService.assertCanSetCost(dto, user);
    // Désactiver est une permission distincte de la modification (docs/permissions.md).
    if (
      dto.isActive !== undefined &&
      !user.permissions.includes(PERMISSIONS.PRODUCT_DISABLE)
    ) {
      throw new BusinessException(
        ErrorCode.FORBIDDEN_PERMISSION,
        'Permission requise pour activer ou désactiver un produit : product.disable',
        HttpStatus.FORBIDDEN,
      );
    }

    return this.prisma.$transaction(async (tx) => {
      await ProductsService.lockWrites(tx);
      // La réception écrit le coût sans `lockWrites` : on tient la LIGNE, pour
      // que « aucune réception » reste vrai jusqu'à l'écriture du coût.
      // NO KEY : n'empêche pas les ventes et mouvements qui référencent le
      // produit, mais attend (et fait attendre) l'écriture du coût par une
      // réception.
      await tx.$queryRaw`SELECT "id" FROM "Product" WHERE "id" = ${id}::uuid FOR NO KEY UPDATE`;
      const before = await tx.product.findUnique({
        where: { id },
        include: PRODUCT_INCLUDE,
      });
      if (!before) throw ProductsService.notFound();
      // Seuls les rattachements MODIFIÉS sont contrôlés : un formulaire renvoyé tel
      // quel ne doit pas échouer parce que sa catégorie a été désactivée entre-temps.
      await this.assertReferences(tx, {
        categoryId:
          dto.categoryId !== before.categoryId ? dto.categoryId : undefined,
        taxRateId:
          dto.taxRateId !== before.taxRateId ? dto.taxRateId : undefined,
        mainSupplierId:
          dto.mainSupplierId !== before.mainSupplierId
            ? dto.mainSupplierId
            : undefined,
        storageLocationId:
          dto.storageLocationId !== before.storageLocationId
            ? dto.storageLocationId
            : undefined,
      });

      const data: Prisma.ProductUncheckedUpdateInput = {};
      if (dto.sku !== undefined && dto.sku !== before.sku) {
        await ProductsService.assertSkuFree(tx, dto.sku, id);
        data.sku = dto.sku;
      }
      if (dto.barcode !== undefined) {
        const barcode = normalizeBarcode(dto.barcode);
        if (barcode !== before.barcode) {
          await ProductsService.assertBarcodeFree(tx, barcode);
          data.barcode = barcode;
        }
      }
      if (dto.name !== undefined) data.name = dto.name;
      if (dto.description !== undefined) data.description = dto.description;
      if (dto.brand !== undefined) data.brand = dto.brand;
      if (dto.unit !== undefined && dto.unit !== before.unit) {
        // Le journal de stock est exprimé dans l'unité du produit : passer de la
        // pièce au mètre réinterpréterait tout l'historique.
        const moved = await tx.stockMovement.findFirst({
          where: { productId: id },
          select: { id: true },
        });
        if (moved) {
          throw new BusinessException(
            ErrorCode.INVALID_STATE_TRANSITION,
            'Unité figée : ce produit a déjà des mouvements de stock',
            HttpStatus.CONFLICT,
          );
        }
        data.unit = dto.unit;
      }
      if (dto.categoryId !== undefined) data.categoryId = dto.categoryId;
      if (dto.taxRateId !== undefined) data.taxRateId = dto.taxRateId;
      if (dto.mainSupplierId !== undefined)
        data.mainSupplierId = dto.mainSupplierId;
      if (dto.storageLocationId !== undefined)
        data.storageLocationId = dto.storageLocationId;
      if (dto.minThreshold !== undefined) {
        data.minThreshold = ProductsService.threshold(
          dto.minThreshold,
          'minThreshold',
        );
      }
      if (dto.safetyStock !== undefined) {
        data.safetyStock = ProductsService.threshold(
          dto.safetyStock,
          'safetyStock',
        );
      }
      if (dto.allowBackorder !== undefined)
        data.allowBackorder = dto.allowBackorder;
      if (dto.isActive !== undefined) data.isActive = dto.isActive;
      if (
        dto.purchasePriceHt !== undefined &&
        dto.purchasePriceHt !== before.lastPurchasePriceHt
      ) {
        // Règle 5 : le coût est le dernier prix RÉCEPTIONNÉ. La saisie comble
        // (ou corrige) un coût tant qu'AUCUNE réception n'existe ; ensuite
        // seules les réceptions le fixent. La ligne produit est verrouillée
        // plus haut : une réception simultanée passe avant ou après, jamais
        // écrasée.
        const received = await tx.receptionLine.count({
          where: { productId: id },
        });
        if (received > 0) {
          throw new BusinessException(
            ErrorCode.INVALID_STATE_TRANSITION,
            'Prix d’achat fixé par les réceptions : il ne se modifie plus à la main',
            HttpStatus.CONFLICT,
          );
        }
        data.lastPurchasePriceHt = dto.purchasePriceHt;
      }

      const product = await tx.product.update({
        where: { id },
        data,
        include: PRODUCT_INCLUDE,
      });
      const after = ProductsService.toDto(product);
      const oldValue = ProductsService.auditSnapshot(
        ProductsService.toDto(before),
      );
      const newValue = ProductsService.auditSnapshot(after);
      // Un formulaire renvoyé sans changement n'encombre pas le journal.
      if (JSON.stringify(oldValue) !== JSON.stringify(newValue)) {
        await writeAudit(tx, actor, {
          action: 'UPDATE',
          entityType: 'Product',
          entityId: id,
          oldValue,
          newValue,
        });
      }
      return after;
    });
  }

  /// Stock présent au moment de la saisie : un mouvement AJUSTEMENT_INVENTAIRE
  /// par lieu (règle 2 : la projection suit le journal, dans la transaction de
  /// la création). Seuls le MAGASIN et le DÉPÔT portent du stock.
  private async applyInitialStock(
    tx: Db,
    productId: string,
    lines: { locationId: string; quantity: string }[],
    actor: ActorContext,
  ): Promise<Prisma.InputJsonArray> {
    const applied: Prisma.InputJsonObject[] = [];
    const seen = new Set<string>();
    for (const line of lines) {
      const invalid = (message: string) =>
        new BusinessException(
          ErrorCode.VALIDATION_FAILED,
          `initialStock : ${message}`,
          HttpStatus.UNPROCESSABLE_ENTITY,
        );
      if (seen.has(line.locationId)) throw invalid('un lieu est répété');
      seen.add(line.locationId);
      const quantity = parseQuantity(line.quantity, 'initialStock.quantity');
      if (quantity.isZero()) continue;
      if (quantity.isNegative()) throw invalid('quantité négative');
      const location = await tx.location.findUnique({
        where: { id: line.locationId },
        select: { type: true },
      });
      if (location?.type !== 'MAGASIN' && location?.type !== 'DEPOT') {
        throw invalid('le stock initial se pose au magasin ou au dépôt');
      }
      const movement = await this.ledger.applyMovement(tx, {
        productId,
        locationId: line.locationId,
        quantity,
        type: 'AJUSTEMENT_INVENTAIRE',
        operationType: 'PRODUCT',
        operationId: productId,
        userId: actor.userId,
        comment: 'Stock initial à la création du produit',
      });
      applied.push({
        locationId: line.locationId,
        quantity: movement.quantityAfter,
        movementId: movement.movementId,
      });
    }
    return applied;
  }

  private static async lockWrites(tx: Db) {
    await tx.$executeRaw`SELECT pg_advisory_xact_lock(${PRODUCT_WRITE_LOCK}::int, 0)`;
  }

  /// Code interne EAN-13 : `nextval` ne rend jamais deux fois la même valeur, même
  /// en concurrence ou après rollback ; la contrainte UNIQUE reste le filet final.
  private static async nextInternalBarcode(tx: Db): Promise<string> {
    for (let attempt = 0; attempt < INTERNAL_BARCODE_ATTEMPTS; attempt++) {
      const [{ value }] = await tx.$queryRaw<{ value: bigint }[]>`
        SELECT nextval('product_internal_barcode_seq') AS value`;
      const code = internalBarcode(value);
      const taken = await tx.product.findUnique({
        where: { barcode: code },
        select: { id: true },
      });
      if (!taken) return code;
    }
    throw new BusinessException(
      ErrorCode.CONFLICT,
      'Impossible de générer un code-barres interne libre, réessayez',
      HttpStatus.CONFLICT,
    );
  }

  private static async assertSkuFree(tx: Db, sku: string, exceptId?: string) {
    const taken = await tx.product.findFirst({
      where: {
        sku: { equals: sku, mode: 'insensitive' },
        ...(exceptId && { id: { not: exceptId } }),
      },
      select: { id: true },
    });
    if (taken) {
      throw new BusinessException(
        ErrorCode.CONFLICT,
        `La référence « ${sku} » est déjà utilisée par un autre produit`,
        HttpStatus.CONFLICT,
      );
    }
  }

  private static async assertBarcodeFree(tx: Db, barcode: string) {
    const taken = await tx.product.findUnique({
      where: { barcode },
      select: { id: true },
    });
    if (taken) {
      throw new BusinessException(
        ErrorCode.BARCODE_ALREADY_USED,
        `Le code-barres ${barcode} est déjà attribué à un autre produit`,
        HttpStatus.CONFLICT,
      );
    }
  }

  /// Un rattachement inexistant finirait en violation de clé étrangère (500) :
  /// on le refuse proprement. L'emplacement doit être une position du dépôt.
  private async assertReferences(
    tx: Db,
    dto: Pick<
      UpdateProductDto,
      'categoryId' | 'taxRateId' | 'mainSupplierId' | 'storageLocationId'
    >,
  ) {
    const missing = (field: string) =>
      new BusinessException(
        ErrorCode.VALIDATION_FAILED,
        `${field} : référence introuvable ou inactive`,
        HttpStatus.UNPROCESSABLE_ENTITY,
      );
    if (dto.categoryId) {
      const found = await tx.category.findFirst({
        where: { id: dto.categoryId, isActive: true },
      });
      if (!found) throw missing('categoryId');
    }
    if (dto.taxRateId) {
      const found = await tx.taxRate.findFirst({
        where: { id: dto.taxRateId, isActive: true },
      });
      if (!found) throw missing('taxRateId');
    }
    if (dto.mainSupplierId) {
      const found = await tx.supplier.findUnique({
        where: { id: dto.mainSupplierId },
      });
      if (!found) throw missing('mainSupplierId');
    }
    if (dto.storageLocationId) {
      const found = await tx.location.findFirst({
        where: {
          id: dto.storageLocationId,
          type: 'EMPLACEMENT',
          isActive: true,
        },
      });
      if (!found) throw missing('storageLocationId');
    }
  }

  private static threshold(
    raw: string | undefined,
    field: string,
  ): Prisma.Decimal {
    if (raw === undefined) return new Prisma.Decimal(0);
    const value = parseQuantity(raw, field);
    if (value.isNegative()) {
      throw new BusinessException(
        ErrorCode.VALIDATION_FAILED,
        `${field} : doit être positif ou nul`,
        HttpStatus.UNPROCESSABLE_ENTITY,
      );
    }
    return value;
  }

  private static auditSnapshot(product: ProductDto): Prisma.InputJsonValue {
    // `updatedAt` est déjà la date de l'entrée d'audit.
    const snapshot: Partial<ProductDto> = { ...product };
    delete snapshot.updatedAt;
    return snapshot as Prisma.InputJsonObject;
  }

  private static notFound() {
    return new BusinessException(
      ErrorCode.NOT_FOUND,
      'Produit introuvable',
      HttpStatus.NOT_FOUND,
    );
  }
}
