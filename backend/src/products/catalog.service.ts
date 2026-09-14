import { HttpStatus, Injectable } from '@nestjs/common';
import { BusinessException } from '../common/business.exception';
import { ErrorCode } from '../common/error-codes';
import { Category, Prisma, TaxRate } from '../generated/prisma/client';
import { LocationsService } from '../locations/locations.service';
import { PrismaService } from '../prisma/prisma.service';
import { CatalogChangesDto, CatalogChangesQueryDto } from './dto/catalog.dto';
import {
  CategoryDto,
  CreateCategoryDto,
  PriceTierDto,
  TaxRateDto,
  UpdateCategoryDto,
} from './dto/product.dto';
import { ProductsService } from './products.service';

type Db = Prisma.TransactionClient;

/// Sérialise les créations/renommages de catégories : le nom est unique par
/// parent SANS la casse, ce qu'aucune contrainte DB simple n'exprime.
const CATEGORY_NAMES_LOCK = 7302;

/// Une ligne n'est servie par le delta qu'une fois plus vieille que ce délai.
/// ponytail: couvre les transactions d'écriture du catalogue (quelques ms) ; une
/// transaction plus longue que ce délai pourrait être sautée — passer alors à un
/// curseur par numéro de version (séquence) plutôt que par `updatedAt`.
export const CATALOG_SETTLE_MS = 5_000;

type Cursor = [string, string]; // [updatedAt ISO, id]
type CatalogCursor = Partial<
  Record<'products' | 'categories' | 'locations' | 'taxRates', Cursor>
>;

@Injectable()
export class CatalogService {
  constructor(private readonly prisma: PrismaService) {}

  static categoryToDto(category: Category): CategoryDto {
    return {
      id: category.id,
      name: category.name,
      parentId: category.parentId,
      description: category.description,
      isActive: category.isActive,
      updatedAt: category.updatedAt,
    };
  }

  static taxRateToDto(taxRate: TaxRate): TaxRateDto {
    return {
      id: taxRate.id,
      code: taxRate.code,
      name: taxRate.name,
      rate: taxRate.rate.toFixed(2),
      isDefault: taxRate.isDefault,
      isActive: taxRate.isActive,
      updatedAt: taxRate.updatedAt,
    };
  }

  /// Liste plate, inactives comprises : le client construit l'arbre (2 niveaux).
  async categories(): Promise<CategoryDto[]> {
    const rows = await this.prisma.category.findMany({
      orderBy: [{ name: 'asc' }, { id: 'asc' }],
    });
    return rows.map(CatalogService.categoryToDto);
  }

  async createCategory(dto: CreateCategoryDto): Promise<CategoryDto> {
    return this.prisma.$transaction(async (tx) => {
      const parentId = dto.parentId ?? null;
      if (parentId) await CatalogService.assertRootParent(tx, parentId);
      await CatalogService.assertNameFree(tx, dto.name, parentId);
      const category = await tx.category.create({
        data: {
          id: dto.id,
          name: dto.name,
          parentId,
          description: dto.description ?? null,
        },
      });
      return CatalogService.categoryToDto(category);
    });
  }

  async updateCategory(
    id: string,
    dto: UpdateCategoryDto,
  ): Promise<CategoryDto> {
    return this.prisma.$transaction(async (tx) => {
      const before = await tx.category.findUnique({
        where: { id },
        include: { _count: { select: { children: true } } },
      });
      if (!before) {
        throw new BusinessException(
          ErrorCode.NOT_FOUND,
          'Catégorie introuvable',
          HttpStatus.NOT_FOUND,
        );
      }
      const parentId =
        dto.parentId !== undefined ? dto.parentId : before.parentId;
      if (
        dto.parentId !== undefined &&
        parentId !== before.parentId &&
        parentId
      ) {
        if (parentId === id) throw CatalogService.depthError();
        // Une catégorie qui a des sous-catégories ne peut pas devenir sous-catégorie.
        if (before._count.children > 0) throw CatalogService.depthError();
        await CatalogService.assertRootParent(tx, parentId);
      }
      const name = dto.name ?? before.name;
      if (
        name.toLowerCase() !== before.name.toLowerCase() ||
        parentId !== before.parentId
      ) {
        await CatalogService.assertNameFree(tx, name, parentId, id);
      }
      const category = await tx.category.update({
        where: { id },
        data: {
          name,
          parentId,
          ...(dto.description !== undefined && {
            description: dto.description,
          }),
          ...(dto.isActive !== undefined && { isActive: dto.isActive }),
        },
      });
      return CatalogService.categoryToDto(category);
    });
  }

  async priceTiers(): Promise<PriceTierDto[]> {
    const rows = await this.prisma.priceTier.findMany({
      where: { isActive: true },
      orderBy: [{ isDefault: 'desc' }, { code: 'asc' }],
    });
    return rows.map(({ id, code, name, isDefault }) => ({
      id,
      code,
      name,
      isDefault,
    }));
  }

  async taxRates(): Promise<TaxRateDto[]> {
    const rows = await this.prisma.taxRate.findMany({
      where: { isActive: true },
      orderBy: [{ isDefault: 'desc' }, { rate: 'asc' }],
    });
    return rows.map(CatalogService.taxRateToDto);
  }

  /// Descente delta du catalogue (docs/context.md : catalogue complet en local,
  /// delta only). Un curseur `(updatedAt, id)` PAR TYPE : robuste aux mises à jour
  /// de masse au même instant. Inactifs compris — le client doit les masquer.
  async changes(query: CatalogChangesQueryDto): Promise<CatalogChangesDto> {
    const cursor = CatalogService.decodeCursor(query.cursor);
    const settledBefore = new Date(Date.now() - CATALOG_SETTLE_MS);
    const take = query.limit + 1;

    const window = (after: Cursor | undefined) => ({
      where: {
        updatedAt: { lte: settledBefore },
        ...(after && {
          OR: [
            { updatedAt: { gt: new Date(after[0]) } },
            { updatedAt: new Date(after[0]), id: { gt: after[1] } },
          ],
        }),
      },
      orderBy: [{ updatedAt: 'asc' as const }, { id: 'asc' as const }],
      take,
    });

    const [products, categories, locations, taxRates] = await Promise.all([
      this.prisma.product.findMany(window(cursor.products)),
      this.prisma.category.findMany(window(cursor.categories)),
      this.prisma.location.findMany(window(cursor.locations)),
      this.prisma.taxRate.findMany(window(cursor.taxRates)),
    ]);

    let hasMore = false;
    const page = <T extends { updatedAt: Date; id: string }>(
      rows: T[],
      key: keyof CatalogCursor,
    ): T[] => {
      if (rows.length > query.limit) {
        hasMore = true;
        rows = rows.slice(0, query.limit);
      }
      const last = rows[rows.length - 1];
      if (last) cursor[key] = [last.updatedAt.toISOString(), last.id];
      return rows;
    };

    return {
      products: page(products, 'products').map(ProductsService.toDto),
      categories: page(categories, 'categories').map(
        CatalogService.categoryToDto,
      ),
      locations: page(locations, 'locations').map(LocationsService.toDto),
      taxRates: page(taxRates, 'taxRates').map(CatalogService.taxRateToDto),
      cursor: Buffer.from(JSON.stringify(cursor)).toString('base64url'),
      hasMore,
    };
  }

  private static decodeCursor(raw: string | undefined): CatalogCursor {
    if (!raw) return {};
    const invalid = new BusinessException(
      ErrorCode.VALIDATION_FAILED,
      'Curseur de synchronisation invalide',
    );
    let parsed: unknown;
    try {
      parsed = JSON.parse(Buffer.from(raw, 'base64url').toString('utf8'));
    } catch {
      throw invalid;
    }
    if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed))
      throw invalid;
    const cursor: CatalogCursor = {};
    for (const key of [
      'products',
      'categories',
      'locations',
      'taxRates',
    ] as const) {
      const value = (parsed as Record<string, unknown>)[key];
      if (value === undefined) continue;
      const valid =
        Array.isArray(value) &&
        value.length === 2 &&
        typeof value[0] === 'string' &&
        !Number.isNaN(Date.parse(value[0])) &&
        typeof value[1] === 'string' &&
        /^[0-9a-f-]{36}$/i.test(value[1]);
      if (!valid) throw invalid;
      cursor[key] = value as Cursor;
    }
    return cursor;
  }

  private static async assertRootParent(tx: Db, parentId: string) {
    const parent = await tx.category.findUnique({ where: { id: parentId } });
    if (!parent || !parent.isActive) {
      throw new BusinessException(
        ErrorCode.VALIDATION_FAILED,
        'parentId : catégorie parente introuvable ou inactive',
        HttpStatus.UNPROCESSABLE_ENTITY,
      );
    }
    if (parent.parentId) throw CatalogService.depthError();
  }

  private static async assertNameFree(
    tx: Db,
    name: string,
    parentId: string | null,
    exceptId?: string,
  ) {
    await tx.$executeRaw`SELECT pg_advisory_xact_lock(${CATEGORY_NAMES_LOCK}::int, 0)`;
    const taken = await tx.category.findFirst({
      where: {
        name: { equals: name, mode: 'insensitive' },
        parentId,
        ...(exceptId && { id: { not: exceptId } }),
      },
      select: { id: true },
    });
    if (taken) {
      throw new BusinessException(
        ErrorCode.CONFLICT,
        `La catégorie « ${name} » existe déjà à cet endroit`,
        HttpStatus.CONFLICT,
      );
    }
  }

  private static depthError() {
    return new BusinessException(
      ErrorCode.VALIDATION_FAILED,
      'Deux niveaux maximum : catégorie → sous-catégorie',
      HttpStatus.UNPROCESSABLE_ENTITY,
    );
  }
}
