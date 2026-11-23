import { readFileSync } from 'fs';
import { join } from 'path';
import { Prisma } from '../src/generated/prisma/client';
import { PrismaService } from '../src/prisma/prisma.service';
import { createE2eApp, E2eApp } from './helpers/e2e-app';

/// QUANTITÉ UNIQUE (décision MEDMEDBEN du 2026-11-23) : la migration verse au
/// magasin le stock tenu ailleurs, par des mouvements (règle 2), en un bloc,
/// et se rejoue sans effet.
describe('Quantité unique — migration (e2e)', () => {
  let e2e: E2eApp;
  let prisma: PrismaService;
  const suffix = Date.now();
  const productIds: string[] = [];
  const sql = readFileSync(
    join(
      __dirname,
      '../prisma/migrations/20261123090000_single_quantity/migration.sql',
    ),
    'utf8',
  );

  beforeAll(async () => {
    e2e = await createE2eApp();
    prisma = e2e.prisma;
  });

  afterAll(async () => {
    await prisma.stockMovement.deleteMany({
      where: { productId: { in: productIds } },
    });
    await prisma.product.deleteMany({ where: { id: { in: productIds } } });
    await e2e.app.close();
  });

  const product = async (n: number) => {
    const created = await prisma.product.create({
      data: {
        sku: `E2E-QTY-${suffix}-${n}`,
        barcode: `Q${String(suffix).slice(-8)}${n}`,
        name: `Produit quantité ${n}`,
        splitPending: true,
      },
    });
    productIds.push(created.id);
    return created.id;
  };

  const qty = async (productId: string, locationId: string) =>
    (
      await prisma.stock.findUnique({
        where: { productId_locationId: { productId, locationId } },
      })
    )?.quantity.toString();

  it('dépôt versé au magasin (positif comme négatif), tracé, rejouable', async () => {
    const store = await prisma.location.findFirstOrThrow({
      where: { type: 'MAGASIN', parentId: null },
      orderBy: { createdAt: 'asc' },
    });
    const depot = await prisma.location.findFirstOrThrow({
      where: { type: 'DEPOT' },
    });
    const a = await product(1);
    const b = await product(2);
    // Projections de départ (données de test) : A = 2 au magasin + 7,5 au
    // dépôt ; B = rien au magasin, -3 au dépôt (transfert à découvert).
    await prisma.stock.createMany({
      data: [
        { productId: a, locationId: store.id, quantity: new Prisma.Decimal(2) },
        {
          productId: a,
          locationId: depot.id,
          quantity: new Prisma.Decimal('7.5'),
        },
        {
          productId: b,
          locationId: depot.id,
          quantity: new Prisma.Decimal(-3),
        },
      ],
    });

    await prisma.$executeRawUnsafe(sql);

    expect(await qty(a, store.id)).toBe('9.5');
    expect(await qty(a, depot.id)).toBe('0');
    expect(await qty(b, store.id)).toBe('-3');
    expect(await qty(b, depot.id)).toBe('0');
    const moves = await prisma.stockMovement.findMany({
      where: { productId: a },
      orderBy: { quantity: 'asc' },
    });
    expect(
      moves.map((m) => [m.locationId, m.quantity.toString(), m.type]),
    ).toEqual([
      [depot.id, '-7.5', 'TRANSFERT_SORTIE'],
      [store.id, '7.5', 'TRANSFERT_ENTREE'],
    ]);
    // Le journal et la projection disent la même chose (règle 2).
    const split = await prisma.product.findMany({
      where: { id: { in: [a, b] }, splitPending: true },
    });
    expect(split).toHaveLength(0);

    // Rejouée : plus rien à verser, aucun nouveau mouvement.
    await prisma.$executeRawUnsafe(sql);
    expect(await prisma.stockMovement.count({ where: { productId: a } })).toBe(
      2,
    );
    expect(await qty(a, store.id)).toBe('9.5');
  });
});
