import * as request from 'supertest';
import { RoleCode } from '../src/common/auth.decorators';
import { PrismaService } from '../src/prisma/prisma.service';
import { createE2eApp, createTestUser, E2eApp } from './helpers/e2e-app';

/// Clients et dettes (P0 n°4) : fiche créée par le vendeur, tarif et plafond
/// fixés par l'ADMIN seul, dette TOUJOURS recalculée, règlement en espèces
/// dans la caisse ouverte, jamais au-delà du dû.
describe('Clients et règlements (e2e)', () => {
  let e2e: E2eApp;
  let prisma: PrismaService;
  let server: E2eApp['server'];

  const suffix = Date.now();
  const PASSWORD = 'MotDePasseTemp1!';
  const userIds: string[] = [];
  const productIds: string[] = [];
  const customerIds: string[] = [];
  const tokens: Record<string, string> = {};
  let magasinId = '';
  let grosId = '';
  let productId = '';

  const as = (token: string) => ({
    get: (url: string) =>
      request(server).get(url).set('Authorization', `Bearer ${token}`),
    post: (url: string) =>
      request(server).post(url).set('Authorization', `Bearer ${token}`),
    patch: (url: string) =>
      request(server).patch(url).set('Authorization', `Bearer ${token}`),
  });

  beforeAll(async () => {
    e2e = await createE2eApp();
    prisma = e2e.prisma;
    server = e2e.server;
    magasinId = (
      await prisma.location.findFirstOrThrow({ where: { type: 'MAGASIN' } })
    ).id;
    const detailId = (
      await prisma.priceTier.findUniqueOrThrow({ where: { code: 'DETAIL' } })
    ).id;
    grosId = (
      await prisma.priceTier.findUniqueOrThrow({ where: { code: 'GROS' } })
    ).id;
    const product = await prisma.product.create({
      data: {
        sku: `E2E-CUST-${suffix}`,
        barcode: `E2E-CUST-BC-${suffix}`,
        name: 'Produit client e2e',
        prices: { create: [{ priceTierId: detailId, priceHt: 100000 }] },
      },
    });
    productId = product.id;
    productIds.push(product.id);
    await prisma.stock.create({
      data: { productId, locationId: magasinId, quantity: '100' },
    });
    for (const [key, role] of [
      ['admin', RoleCode.ADMIN],
      ['vendeur', RoleCode.VENDEUR],
      ['vendeurSansCaisse', RoleCode.VENDEUR],
      ['magasinier', RoleCode.MAGASINIER],
    ] as const) {
      const email = `e2e-cust-${key}-${suffix}@test.local`;
      const user = await createTestUser(prisma, {
        email,
        password: PASSWORD,
        roles: [role],
      });
      userIds.push(user.id);
      tokens[key] = (
        await request(server)
          .post('/api/auth/login')
          .send({ identifier: email, password: PASSWORD })
          .expect(200)
      ).body.accessToken;
    }
    await as(tokens.vendeur)
      .post('/api/cash-sessions')
      .send({ locationId: magasinId, openingFloat: 0 })
      .expect(201);
  });

  afterAll(async () => {
    const sales = await prisma.sale.findMany({
      where: { userId: { in: userIds } },
      select: { id: true },
    });
    await prisma.auditLog.deleteMany({
      where: {
        OR: [
          { userId: { in: userIds } },
          { entityId: { in: [...customerIds, ...sales.map((s) => s.id)] } },
        ],
      },
    });
    await prisma.cashMovement.deleteMany({
      where: { userId: { in: userIds } },
    });
    await prisma.customerPayment.deleteMany({
      where: { customerId: { in: customerIds } },
    });
    await prisma.sale.deleteMany({ where: { userId: { in: userIds } } });
    await prisma.cashSession.deleteMany({ where: { userId: { in: userIds } } });
    await prisma.stockMovement.deleteMany({
      where: { productId: { in: productIds } },
    });
    await prisma.stock.deleteMany({ where: { productId: { in: productIds } } });
    await prisma.product.deleteMany({ where: { id: { in: productIds } } });
    await prisma.customer.deleteMany({ where: { id: { in: customerIds } } });
    await prisma.user.deleteMany({ where: { id: { in: userIds } } });
    await e2e.app.close();
  });

  const createCustomer = async (token: string, body: object) => {
    const res = await as(token).post('/api/customers').send(body);
    if (res.status === 201) customerIds.push(res.body.id);
    return res;
  };

  it('le VENDEUR crée la fiche ; tarif et plafond : 403 pour lui, OK pour l’ADMIN (audité)', async () => {
    const created = await createCustomer(tokens.vendeur, {
      name: `Électricité Benali ${suffix}`,
      phone: '0555 12 34 56',
    });
    expect(created.status).toBe(201);
    expect(created.body).toMatchObject({
      creditLimit: 0,
      balanceDue: 0,
      priceTierId: null,
    });

    expect(
      (
        await createCustomer(tokens.vendeur, {
          name: 'Tricheur',
          creditLimit: 100000,
        })
      ).status,
    ).toBe(403);
    await as(tokens.vendeur)
      .patch(`/api/customers/${created.body.id}`)
      .send({ creditLimit: 999999 })
      .expect(403);

    const terms = await as(tokens.admin)
      .patch(`/api/customers/${created.body.id}`)
      .send({ creditLimit: 500000, priceTierId: grosId })
      .expect(200);
    expect(terms.body).toMatchObject({
      creditLimit: 500000,
      priceTierId: grosId,
    });
    const audit = await prisma.auditLog.findFirst({
      where: {
        entityType: 'Customer',
        entityId: created.body.id,
        action: 'UPDATE',
      },
    });
    expect(audit?.newValue).toMatchObject({ creditLimit: 500000 });
  });

  it('MAGASINIER consulte seulement ; recherche par nom et téléphone', async () => {
    const name = `Client recherche ${suffix}`;
    const c = await createCustomer(tokens.admin, { name, phone: '0661998877' });
    expect(c.status).toBe(201);
    expect(
      (await createCustomer(tokens.magasinier, { name: 'Interdit' })).status,
    ).toBe(403);

    const byName = await as(tokens.magasinier)
      .get(`/api/customers?q=${encodeURIComponent('recherche ' + suffix)}`)
      .expect(200);
    expect(byName.body.data.map((x: { id: string }) => x.id)).toEqual([
      c.body.id,
    ]);
    const byPhone = await as(tokens.magasinier)
      .get('/api/customers?q=0661998877')
      .expect(200);
    expect(byPhone.body.data.map((x: { id: string }) => x.id)).toContain(
      c.body.id,
    );
  });

  it('dette : vente à crédit, règlement partiel en espèces, crédit à nouveau disponible', async () => {
    const c = (
      await createCustomer(tokens.admin, {
        name: `Client dette ${suffix}`,
        creditLimit: 150000,
      })
    ).body;

    // 1 000,00 HT sans TVA → 100 000 centimes à crédit
    await as(tokens.vendeur)
      .post('/api/sales')
      .send({
        customerId: c.id,
        lines: [{ productId, quantity: '1' }],
        paidAmount: 0,
      })
      .expect(201);
    expect(
      (await as(tokens.vendeur).get(`/api/customers/${c.id}`).expect(200)).body
        .balanceDue,
    ).toBe(100000);
    // Au-delà du plafond : refusé.
    await as(tokens.vendeur)
      .post('/api/sales')
      .send({
        customerId: c.id,
        lines: [{ productId, quantity: '1' }],
        paidAmount: 0,
      })
      .expect(422);

    const before = (
      await as(tokens.vendeur).get('/api/cash-sessions/current').expect(200)
    ).body;
    const payment = await as(tokens.vendeur)
      .post('/api/payments/customer')
      .send({ customerId: c.id, amount: 60000 })
      .expect(201);
    expect(payment.body.balanceDue).toBe(40000);
    const after = (
      await as(tokens.vendeur).get('/api/cash-sessions/current').expect(200)
    ).body;
    expect(after.currentAmount - before.currentAmount).toBe(60000);

    // Dette 40 000 + nouveau crédit 100 000 = 140 000 ≤ 150 000 : accepté.
    await as(tokens.vendeur)
      .post('/api/sales')
      .send({
        customerId: c.id,
        lines: [{ productId, quantity: '1' }],
        paidAmount: 0,
      })
      .expect(201);
  });

  it('règlement : jamais au-delà du dû, jamais sans caisse ouverte, ni sur la vente d’un autre', async () => {
    const c = (
      await createCustomer(tokens.admin, {
        name: `Client règle ${suffix}`,
        creditLimit: 500000,
      })
    ).body;
    const other = (
      await createCustomer(tokens.admin, {
        name: `Autre ${suffix}`,
        creditLimit: 500000,
      })
    ).body;
    const sale = (
      await as(tokens.vendeur)
        .post('/api/sales')
        .send({
          customerId: c.id,
          lines: [{ productId, quantity: '1' }],
          paidAmount: 0,
        })
        .expect(201)
    ).body;

    await as(tokens.vendeur)
      .post('/api/payments/customer')
      .send({ customerId: c.id, amount: 100001 })
      .expect(422);
    const noCash = await as(tokens.vendeurSansCaisse)
      .post('/api/payments/customer')
      .send({ customerId: c.id, amount: 1000 })
      .expect(422);
    expect(noCash.body.code).toBe('CASH_SESSION_REQUIRED');
    await as(tokens.vendeur)
      .post('/api/payments/customer')
      .send({ customerId: other.id, saleId: sale.id, amount: 1000 })
      .expect(422);
    await as(tokens.magasinier)
      .post('/api/payments/customer')
      .send({ customerId: c.id, amount: 1000 })
      .expect(403);

    // Réglée sur la vente : son reste dû suit.
    await as(tokens.vendeur)
      .post('/api/payments/customer')
      .send({ customerId: c.id, saleId: sale.id, amount: 100000 })
      .expect(201);
    const settled = await as(tokens.vendeur)
      .get(`/api/sales/${sale.id}`)
      .expect(200);
    expect(settled.body.remainingAmount).toBe(0);
  });
});
