import * as request from 'supertest';
import { RoleCode } from '../src/common/auth.decorators';
import { PrismaService } from '../src/prisma/prisma.service';
import { createE2eApp, createTestUser, E2eApp } from './helpers/e2e-app';

/// Feature P0 n°3 « Stock » : lecture de la projection et du journal, pertes /
/// casse avec validation admin pour le magasinier (docs/permissions.md ⚠️,
/// décision MEDMEDBEN 2026-09-14), règles 2, 7 et 9 de CLAUDE.md.
describe('Stock (e2e)', () => {
  let e2e: E2eApp;
  let prisma: PrismaService;
  let server: E2eApp['server'];

  const suffix = Date.now();
  const PASSWORD = 'MotDePasseTemp1!';
  const userIds: string[] = [];
  const productIds: string[] = [];
  let depotId = '';
  let counter = 0;
  const tokens = { admin: '', vendeur: '', magasinier: '' };

  const as = (token: string) => ({
    get: (url: string) =>
      request(server).get(url).set('Authorization', `Bearer ${token}`),
    post: (url: string) =>
      request(server).post(url).set('Authorization', `Bearer ${token}`),
  });

  /// Produit avec un stock initial posé en base (fixture de départ).
  const productWithStock = async (quantity: string) => {
    const n = ++counter;
    const product = await prisma.product.create({
      data: {
        sku: `E2E-STK-${suffix}-${n}`,
        barcode: `E2E-STK-BC-${suffix}-${n}`,
        name: `Produit stock ${n}`,
      },
    });
    productIds.push(product.id);
    await prisma.stock.create({
      data: { productId: product.id, locationId: depotId, quantity },
    });
    return product.id;
  };

  const stockOf = async (productId: string) =>
    (
      await prisma.stock.findUniqueOrThrow({
        where: { productId_locationId: { productId, locationId: depotId } },
      })
    ).quantity.toFixed(3);

  const declare = (token: string, productId: string, quantity = '2.000') =>
    as(token).post('/api/stock/losses').send({
      productId,
      locationId: depotId,
      quantity,
      comment: 'Carton écrasé',
    });

  beforeAll(async () => {
    e2e = await createE2eApp();
    prisma = e2e.prisma;
    server = e2e.server;
    depotId = (
      await prisma.location.findFirstOrThrow({ where: { type: 'DEPOT' } })
    ).id;
    for (const [key, role] of [
      ['admin', RoleCode.ADMIN],
      ['vendeur', RoleCode.VENDEUR],
      ['magasinier', RoleCode.MAGASINIER],
    ] as const) {
      const email = `e2e-stock-${key}-${suffix}@test.local`;
      const user = await createTestUser(prisma, {
        email,
        password: PASSWORD,
        roles: [role],
      });
      userIds.push(user.id);
      const login = await request(server)
        .post('/api/auth/login')
        .send({ identifier: email, password: PASSWORD })
        .expect(200);
      tokens[key] = login.body.accessToken;
    }
  });

  afterAll(async () => {
    const declarations = await prisma.stockLossDeclaration.findMany({
      where: { productId: { in: productIds } },
      select: { id: true },
    });
    await prisma.auditLog.deleteMany({
      where: {
        OR: [
          { entityId: { in: declarations.map((d) => d.id) } },
          { userId: { in: userIds } },
        ],
      },
    });
    await prisma.stockLossDeclaration.deleteMany({
      where: { productId: { in: productIds } },
    });
    await prisma.stockMovement.deleteMany({
      where: { productId: { in: productIds } },
    });
    await prisma.stock.deleteMany({ where: { productId: { in: productIds } } });
    await prisma.product.deleteMany({ where: { id: { in: productIds } } });
    await prisma.user.deleteMany({ where: { id: { in: userIds } } });
    await e2e.app.close();
  });

  describe('pertes / casse', () => {
    it('ADMIN : appliquée tout de suite — mouvement négatif, projection, audit', async () => {
      const productId = await productWithStock('10.000');

      const res = await declare(tokens.admin, productId).expect(201);

      expect(res.body).toMatchObject({ status: 'VALIDEE', quantity: '2.000' });
      expect(await stockOf(productId)).toBe('8.000');
      const movement = await prisma.stockMovement.findUniqueOrThrow({
        where: { id: res.body.movementId },
      });
      expect(movement.quantity.toFixed(3)).toBe('-2.000');
      expect(movement.type).toBe('PERTE_CASSE');
      expect(movement.operationId).toBe(res.body.id);
      const audit = await prisma.auditLog.findFirst({
        where: { entityType: 'StockLossDeclaration', entityId: res.body.id },
      });
      expect(audit?.action).toBe('ADJUST');
    });

    it('MAGASINIER : EN ATTENTE, le stock ne bouge PAS avant validation', async () => {
      const productId = await productWithStock('10.000');

      const res = await declare(tokens.magasinier, productId).expect(201);

      expect(res.body).toMatchObject({
        status: 'EN_ATTENTE',
        movementId: null,
      });
      expect(await stockOf(productId)).toBe('10.000');
      expect(await prisma.stockMovement.count({ where: { productId } })).toBe(
        0,
      );
    });

    it('validation ADMIN : le stock baisse, déclarant et validateur tracés', async () => {
      const productId = await productWithStock('10.000');
      const pending = (
        await declare(tokens.magasinier, productId, '3.500').expect(201)
      ).body;

      const res = await as(tokens.admin)
        .post(`/api/stock/losses/${pending.id}/validate`)
        .expect(200);

      expect(res.body).toMatchObject({
        status: 'VALIDEE',
        declaredById: userIds[2],
        decidedById: userIds[0],
      });
      expect(await stockOf(productId)).toBe('6.500');
      const movement = await prisma.stockMovement.findUniqueOrThrow({
        where: { id: res.body.movementId },
      });
      // Le mouvement est attribué à celui qui a constaté la perte.
      expect(movement.userId).toBe(userIds[2]);
      const audit = await prisma.auditLog.findMany({
        where: { entityType: 'StockLossDeclaration', entityId: pending.id },
        orderBy: { createdAt: 'asc' },
      });
      expect(audit.map((a) => a.action)).toEqual(['CREATE', 'VALIDATE']);
    });

    it('refus ADMIN : aucun mouvement, motif gardé, déclaration conservée', async () => {
      const productId = await productWithStock('10.000');
      const pending = (await declare(tokens.magasinier, productId).expect(201))
        .body;

      const res = await as(tokens.admin)
        .post(`/api/stock/losses/${pending.id}/reject`)
        .send({ note: 'Carton retrouvé intact' })
        .expect(200);

      expect(res.body).toMatchObject({
        status: 'REFUSEE',
        decisionNote: 'Carton retrouvé intact',
        movementId: null,
      });
      expect(await stockOf(productId)).toBe('10.000');
      // Une décision est définitive : ni revalidée, ni re-refusée.
      await as(tokens.admin)
        .post(`/api/stock/losses/${pending.id}/validate`)
        .expect(409);
      await as(tokens.admin)
        .post(`/api/stock/losses/${pending.id}/reject`)
        .expect(409);
    });

    it('deux validations simultanées : UNE seule perte appliquée', async () => {
      const productId = await productWithStock('10.000');
      const pending = (await declare(tokens.magasinier, productId).expect(201))
        .body;

      const results = await Promise.all(
        [1, 2].map(() =>
          as(tokens.admin).post(`/api/stock/losses/${pending.id}/validate`),
        ),
      );

      expect(results.map((r) => r.status).sort()).toEqual([200, 409]);
      expect(await stockOf(productId)).toBe('8.000');
      expect(await prisma.stockMovement.count({ where: { productId } })).toBe(
        1,
      );
    });

    it('validation qui rendrait le stock négatif : refusée, la déclaration reste EN ATTENTE', async () => {
      const productId = await productWithStock('1.000');
      const pending = (
        await declare(tokens.magasinier, productId, '5.000').expect(201)
      ).body;

      const res = await as(tokens.admin)
        .post(`/api/stock/losses/${pending.id}/validate`)
        .expect(422);

      expect(res.body.code).toBe('STOCK_NEGATIVE');
      const stored = await prisma.stockLossDeclaration.findUniqueOrThrow({
        where: { id: pending.id },
      });
      expect(stored.status).toBe('EN_ATTENTE');
      expect(await stockOf(productId)).toBe('1.000');
    });

    it('ADMIN sans stock suffisant : rien n’est créé (atomicité)', async () => {
      const productId = await productWithStock('1.000');
      const res = await declare(tokens.admin, productId, '5.000').expect(422);
      expect(res.body.code).toBe('STOCK_NEGATIVE');
      expect(
        await prisma.stockLossDeclaration.count({ where: { productId } }),
      ).toBe(0);
    });

    it('quantité nulle, négative ou mal formée → 422 / 400', async () => {
      const productId = await productWithStock('10.000');
      await declare(tokens.admin, productId, '0').expect(422);
      await declare(tokens.admin, productId, '-2').expect(422);
      await declare(tokens.admin, productId, '1e3').expect(422);
      await declare(tokens.admin, productId, '9'.repeat(30)).expect(400);
    });

    it('matrice : le VENDEUR ne déclare ni ne voit les pertes ; le MAGASINIER ne valide pas', async () => {
      const productId = await productWithStock('10.000');
      await declare(tokens.vendeur, productId).expect(403);
      await as(tokens.vendeur).get('/api/stock/losses').expect(403);

      const pending = (await declare(tokens.magasinier, productId).expect(201))
        .body;
      await as(tokens.magasinier)
        .post(`/api/stock/losses/${pending.id}/validate`)
        .expect(403);
      await as(tokens.magasinier)
        .post(`/api/stock/losses/${pending.id}/reject`)
        .expect(403);
      expect(await stockOf(productId)).toBe('10.000');
    });

    it('liste filtrée par statut, paginée', async () => {
      const productId = await productWithStock('10.000');
      const pending = (await declare(tokens.magasinier, productId).expect(201))
        .body;

      const res = await as(tokens.magasinier)
        .get('/api/stock/losses?status=EN_ATTENTE&limit=200')
        .expect(200);

      expect(res.body.meta).toMatchObject({ page: 1, limit: 200 });
      expect(res.body.data.map((d: { id: string }) => d.id)).toContain(
        pending.id,
      );
      expect(
        res.body.data.every(
          (d: { status: string }) => d.status === 'EN_ATTENTE',
        ),
      ).toBe(true);
    });
  });

  describe('lecture', () => {
    it('stock par produit : quantité, réservé, disponible — 3 rôles', async () => {
      const productId = await productWithStock('12.500');
      await prisma.stock.update({
        where: { productId_locationId: { productId, locationId: depotId } },
        data: { reservedQuantity: '2.500' },
      });

      for (const token of Object.values(tokens)) {
        const res = await as(token)
          .get(`/api/stock?productId=${productId}`)
          .expect(200);
        expect(res.body.meta.total).toBe(1);
        expect(res.body.data[0]).toMatchObject({
          locationId: depotId,
          quantity: '12.500',
          reservedQuantity: '2.500',
          availableQuantity: '10.000',
        });
      }
    });

    it('journal des mouvements : le plus récent d’abord, filtré, jamais modifiable', async () => {
      const productId = await productWithStock('10.000');
      await declare(tokens.admin, productId, '1.000').expect(201);
      await declare(tokens.admin, productId, '2.000').expect(201);

      const res = await as(tokens.vendeur)
        .get(`/api/stock/movements?productId=${productId}&type=PERTE_CASSE`)
        .expect(200);

      expect(res.body.meta.total).toBe(2);
      expect(
        res.body.data.map((m: { quantity: string }) => m.quantity),
      ).toEqual(['-2.000', '-1.000']);
      // Aucune route d'écriture directe du journal ni de la projection (règles 2 et 7).
      await as(tokens.admin).post('/api/stock/movements').send({}).expect(404);
    });

    it('filtres invalides → 400', async () => {
      await as(tokens.admin).get('/api/stock/movements?from=hier').expect(400);
      await as(tokens.admin)
        .get('/api/stock?productId=pas-un-uuid')
        .expect(400);
    });
  });
});
