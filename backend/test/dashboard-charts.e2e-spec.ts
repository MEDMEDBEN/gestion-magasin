import * as request from 'supertest';
import { RoleCode } from '../src/common/auth.decorators';
import { PrismaService } from '../src/prisma/prisma.service';
import { createE2eApp, createTestUser, E2eApp } from './helpers/e2e-app';

/// Graphiques de l'accueil (2026-10-05) : courbe des 30 jours, meilleurs
/// produits, anneau de l'état du stock. Fichier à part : la route est bridée à
/// 30 appels par minute, et la suite principale en consomme déjà l'essentiel.
describe('Tableau de bord — graphiques (e2e)', () => {
  let e2e: E2eApp;
  let prisma: PrismaService;
  let server: E2eApp['server'];

  const suffix = Date.now();
  const PASSWORD = 'MotDePasseTemp1!';
  const userIds: string[] = [];
  const productIds: string[] = [];
  const ids: Record<string, string> = {};
  const tokens: Record<string, string> = {};
  let magasinId: string;

  const dashboard = (token: string) =>
    request(server)
      .get('/api/dashboard')
      .set('Authorization', `Bearer ${token}`);

  const sale = (userId: string, totalTtc: number, soldAt = new Date()) =>
    prisma.sale.create({
      data: {
        number: `E2E-DASHG-${suffix}-${Math.random().toString(36).slice(2, 8)}`,
        userId,
        locationId: magasinId,
        totalHt: totalTtc,
        totalTax: 0,
        totalTtc,
        paidAmount: totalTtc,
        soldAt,
      },
      select: { id: true },
    });

  beforeAll(async () => {
    e2e = await createE2eApp();
    prisma = e2e.prisma;
    server = e2e.server;
    magasinId = (
      await prisma.location.findFirstOrThrow({ where: { type: 'MAGASIN' } })
    ).id;
    for (const [key, role] of [
      ['admin', RoleCode.ADMIN],
      ['vendeur', RoleCode.VENDEUR],
      ['autreVendeur', RoleCode.VENDEUR],
      ['magasinier', RoleCode.MAGASINIER],
    ] as const) {
      const email = `e2e-dashg-${key}-${suffix}@test.local`;
      const user = await createTestUser(prisma, {
        email,
        password: PASSWORD,
        roles: [role],
      });
      userIds.push(user.id);
      ids[key] = user.id;
      tokens[key] = (
        await request(server)
          .post('/api/auth/login')
          .send({ identifier: email, password: PASSWORD })
          .expect(200)
      ).body.accessToken;
    }
  });

  afterAll(async () => {
    await prisma.auditLog.deleteMany({ where: { userId: { in: userIds } } });
    await prisma.cashMovement.deleteMany({
      where: { userId: { in: userIds } },
    });
    await prisma.cashSession.deleteMany({ where: { userId: { in: userIds } } });
    await prisma.sale.deleteMany({ where: { userId: { in: userIds } } });
    await prisma.product.deleteMany({ where: { id: { in: productIds } } });
    await prisma.user.deleteMany({ where: { id: { in: userIds } } });
    await e2e.app.close();
  });

  /// Graphiques de l'accueil (2026-10-05) : 30 jours et meilleurs produits,
  /// MÊME cloisonnement que le CA du jour (le vendeur ne voit que les siennes).
  it('30 jours et meilleurs produits : cloisonnés par vendeur', async () => {
    const produit = await prisma.product.create({
      data: {
        sku: `E2E-DASHG-TOP-${suffix}`,
        barcode: `E2E-DASHG-TOP-BC-${suffix}`,
        name: `Top vente ${suffix}`,
      },
    });
    productIds.push(produit.id);
    const ilYa10Jours = new Date(Date.now() - 10 * 24 * 3600 * 1000);
    const vendue = await sale(ids.vendeur, 9_000_000, ilYa10Jours);
    await prisma.saleLine.create({
      data: {
        saleId: vendue.id,
        productId: produit.id,
        quantity: '3',
        unitPriceHt: 3_000_000,
        lineTotalHt: 9_000_000,
        lineTaxAmount: 0,
        lineTotalTtc: 9_000_000,
      },
    });

    const corps = (await dashboard(tokens.vendeur).expect(200)).body;
    const mien = corps.sales;
    expect(mien.last30Days).toHaveLength(30);
    expect(mien.last30Days.at(-1).day).toBe(corps.day);
    // Les 7 derniers jours sont la fin des 30.
    expect(mien.last7Days).toEqual(mien.last30Days.slice(-7));
    expect(mien.topProducts[0]).toEqual({
      productId: produit.id,
      name: produit.name,
      revenueTtc: 9_000_000,
      quantity: '3.000',
    });

    const autre = (await dashboard(tokens.autreVendeur).expect(200)).body.sales;
    expect(
      autre.topProducts.some(
        (p: { productId: string }) => p.productId === produit.id,
      ),
    ).toBe(false);
    const admin = (await dashboard(tokens.admin).expect(200)).body.sales;
    expect(
      admin.topProducts.some(
        (p: { productId: string }) => p.productId === produit.id,
      ),
    ).toBe(true);
  });

  it('stock : produits sains comptés à part (graphique en anneau)', async () => {
    const stock = (await dashboard(tokens.magasinier).expect(200)).body.stock;
    expect(Number.isInteger(stock.okCount)).toBe(true);
    const actifs = await prisma.product.count({ where: { isActive: true } });
    expect(stock.okCount + stock.lowCount).toBeLessThanOrEqual(actifs);
  });

  /// Infos ajoutées le 2026-10-05 : marge du jour (admin), ma caisse.
  it('marge du jour : admin seul ; ma caisse : qui tient une caisse', async () => {
    const admin = (await dashboard(tokens.admin).expect(200)).body;
    expect(admin.margin).toEqual(
      expect.objectContaining({ uncostedRevenueHt: expect.any(Number) }),
    );
    const vendeur = (await dashboard(tokens.vendeur).expect(200)).body;
    expect(vendeur.margin).toBeNull();
    expect(vendeur.cash).toEqual({
      open: false,
      currentAmount: 0,
      openedAt: null,
    });

    await request(server)
      .post('/api/cash-sessions')
      .set('Authorization', `Bearer ${tokens.vendeur}`)
      .send({ locationId: magasinId, openingFloat: 250000 })
      .expect(201);
    const ouverte = (await dashboard(tokens.vendeur).expect(200)).body.cash;
    expect(ouverte).toMatchObject({ open: true, currentAmount: 250000 });

    // Cloisonné : l'admin voit SA caisse (fermée), jamais celle du vendeur.
    const adminCash = (await dashboard(tokens.admin).expect(200)).body.cash;
    expect(adminCash).toEqual({
      open: false,
      currentAmount: 0,
      openedAt: null,
    });

    const magasinier = (await dashboard(tokens.magasinier).expect(200)).body;
    expect(magasinier.cash).toBeNull();
    expect(magasinier.margin).toBeNull();
  });
});
