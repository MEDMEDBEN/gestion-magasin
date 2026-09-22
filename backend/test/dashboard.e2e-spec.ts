import * as request from 'supertest';
import { RoleCode } from '../src/common/auth.decorators';
import { localDate } from '../src/common/document-number';
import { PrismaService } from '../src/prisma/prisma.service';
import { createE2eApp, createTestUser, E2eApp } from './helpers/e2e-app';

/// Tableau de bord d'accueil (P1 n°15, spec §21).
///
/// Éprouvé en priorité : un bloc qu'un rôle n'a PAS le droit de voir est
/// absent (`null`) et non à zéro ; le CA du jour est cloisonné (le vendeur voit
/// le sien, l'admin voit tout) ; les alertes de stock ignorent le TRANSIT ;
/// chacun ne voit QUE ses propres tâches.
describe('Tableau de bord (e2e)', () => {
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
  let transitId: string;

  const dashboard = (token: string) =>
    request(server)
      .get('/api/dashboard')
      .set('Authorization', `Bearer ${token}`);

  /// Vente VALIDÉE écrite en base : ici on éprouve l'AGRÉGAT, pas la caisse
  /// (le cycle de vente a ses propres tests).
  const sale = (userId: string, totalTtc: number, soldAt = new Date()) =>
    prisma.sale.create({
      data: {
        number: `E2E-DASH-${suffix}-${Math.random().toString(36).slice(2, 8)}`,
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
    transitId = (
      await prisma.location.findFirstOrThrow({ where: { type: 'TRANSIT' } })
    ).id;

    for (const [key, role] of [
      ['admin', RoleCode.ADMIN],
      ['vendeur', RoleCode.VENDEUR],
      ['autreVendeur', RoleCode.VENDEUR],
      ['magasinier', RoleCode.MAGASINIER],
    ] as const) {
      const email = `e2e-dash-${key}-${suffix}@test.local`;
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
    await prisma.sale.deleteMany({ where: { userId: { in: userIds } } });
    await prisma.planningTask.deleteMany({
      where: {
        OR: [
          { assignedToId: { in: userIds } },
          { createdById: { in: userIds } },
        ],
      },
    });
    await prisma.stock.deleteMany({ where: { productId: { in: productIds } } });
    await prisma.product.deleteMany({ where: { id: { in: productIds } } });
    await prisma.user.deleteMany({ where: { id: { in: userIds } } });
    await e2e.app.close();
  });

  it('le résumé est daté de la journée locale (Alger)', async () => {
    const body = (await dashboard(tokens.admin).expect(200)).body;
    expect(body.day).toBe(localDate(new Date()));
  });

  it('un bloc interdit est ABSENT, pas à zéro : le vendeur n’a ni fournisseurs ni réceptions', async () => {
    const body = (await dashboard(tokens.vendeur).expect(200)).body;
    // La matrice ferme les fournisseurs et les achats au vendeur.
    expect(body.suppliers).toBeNull();
    expect(body.purchases).toBeNull();
    // Ce qu'il a le droit de voir est bien là.
    expect(body.sales).not.toBeNull();
    expect(body.customers).not.toBeNull();
    expect(body.tasks).not.toBeNull();
  });

  it('le magasinier ne vend pas : pas de bloc ventes, mais achats et fournisseurs', async () => {
    const body = (await dashboard(tokens.magasinier).expect(200)).body;
    expect(body.sales).toBeNull();
    expect(body.purchases).not.toBeNull();
    expect(body.suppliers).not.toBeNull();
    expect(body.stock).not.toBeNull();
  });

  it('CA du jour : le vendeur voit le SIEN, l’admin voit tout', async () => {
    const hier = new Date(Date.now() - 36 * 3600 * 1000);
    const avant = (await dashboard(tokens.admin).expect(200)).body.sales;
    await sale(ids.vendeur, 150000);
    await sale(ids.autreVendeur, 250000);
    await sale(ids.vendeur, 990000, hier); // hors journée : ignorée

    const mien = (await dashboard(tokens.vendeur).expect(200)).body.sales;
    expect(mien).toEqual({ count: 1, revenueTtc: 150000 });

    const tout = (await dashboard(tokens.admin).expect(200)).body.sales;
    expect(tout.count).toBe(avant.count + 2);
    expect(tout.revenueTtc).toBe(avant.revenueTtc + 400000);
  });

  it('une vente ANNULÉE ne compte pas dans le CA', async () => {
    const created = await sale(ids.autreVendeur, 700000);
    const avec = (await dashboard(tokens.autreVendeur).expect(200)).body.sales;
    await prisma.sale.update({
      where: { id: created.id },
      data: { status: 'ANNULEE', cancelledAt: new Date() },
    });

    const apres = (await dashboard(tokens.autreVendeur).expect(200)).body.sales;
    expect(apres.count).toBe(avec.count - 1);
    expect(apres.revenueTtc).toBe(avec.revenueTtc - 700000);
  });

  it('alerte de stock : sous le seuil et en rupture ; le TRANSIT ne compte pas', async () => {
    const avant = (await dashboard(tokens.magasinier).expect(200)).body.stock;

    const bas = await prisma.product.create({
      data: {
        sku: `E2E-DASH-BAS-${suffix}`,
        barcode: `E2E-DASH-BAS-BC-${suffix}`,
        name: 'Câble sous le seuil',
        minThreshold: '10',
        stocks: { create: [{ locationId: magasinId, quantity: '3' }] },
      },
    });
    productIds.push(bas.id);
    // Rupture en magasin : les 40 pièces en TRANSIT ne sont pas disponibles.
    const enRoute = await prisma.product.create({
      data: {
        sku: `E2E-DASH-TRANSIT-${suffix}`,
        barcode: `E2E-DASH-TRANSIT-BC-${suffix}`,
        name: 'Disjoncteur en route',
        minThreshold: '5',
        stocks: { create: [{ locationId: transitId, quantity: '40' }] },
      },
    });
    productIds.push(enRoute.id);

    const apres = (await dashboard(tokens.magasinier).expect(200)).body.stock;
    expect(apres.lowCount).toBe(avant.lowCount + 2);
    expect(apres.outOfStockCount).toBe(avant.outOfStockCount + 1);
    expect(apres.low).toContainEqual({
      productId: enRoute.id,
      name: 'Disjoncteur en route',
      quantity: '0.000',
      minThreshold: '5.000',
    });
    expect(apres.low.length).toBeLessThanOrEqual(5);
  });

  it('un produit sans seuil (0) n’est jamais « sous le seuil », même à zéro', async () => {
    const avant = (await dashboard(tokens.magasinier).expect(200)).body.stock;
    const sansSeuil = await prisma.product.create({
      data: {
        sku: `E2E-DASH-SANS-${suffix}`,
        barcode: `E2E-DASH-SANS-BC-${suffix}`,
        name: 'Accessoire sans seuil',
        stocks: { create: [{ locationId: magasinId, quantity: '0' }] },
      },
    });
    productIds.push(sansSeuil.id);

    const apres = (await dashboard(tokens.magasinier).expect(200)).body.stock;
    expect(apres.lowCount).toBe(avant.lowCount);
    expect(apres.outOfStockCount).toBe(avant.outOfStockCount + 1);
  });

  it('mes tâches : celles d’un autre membre ne sont jamais comptées', async () => {
    const jour = (offset: number) =>
      localDate(new Date(Date.now() + offset * 24 * 3600 * 1000));
    /// L'API refuse (à raison) de planifier une échéance déjà passée : le retard
    /// s'obtient en antidatant la tâche créée, comme le temps le ferait.
    const task = async (assignee: string, late = false) => {
      const created = (
        await request(server)
          .post('/api/planning-tasks')
          .set('Authorization', `Bearer ${tokens.admin}`)
          .send({
            title: 'Compter la zone A',
            type: 'COMPTAGE',
            assignedToId: ids[assignee],
            scheduledFor: jour(0),
            dueDate: jour(2),
          })
          .expect(201)
      ).body;
      if (late) {
        await prisma.planningTask.update({
          where: { id: created.id },
          data: { dueDate: new Date(`${jour(-3)}T00:00:00Z`) },
        });
      }
      return created;
    };

    await task('magasinier');
    await task('magasinier', true);
    await task('vendeur', true); // à quelqu'un d'autre

    const body = (await dashboard(tokens.magasinier).expect(200)).body;
    expect(body.tasks).toEqual({ open: 2, late: 1 });
  });

  it('sans token : refusé', async () => {
    await request(server).get('/api/dashboard').expect(401);
  });
});
