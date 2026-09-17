import { randomUUID } from 'crypto';
import * as request from 'supertest';
import { RoleCode } from '../src/common/auth.decorators';
import { nextDocumentNumber } from '../src/common/document-number';
import { PrismaService } from '../src/prisma/prisma.service';
import { createE2eApp, createTestUser, E2eApp } from './helpers/e2e-app';

/// Concurrence sur les chemins argent/stock (CONVENTIONS.md, règle 6).
describe('Concurrence argent et stock (e2e)', () => {
  let e2e: E2eApp;
  let prisma: PrismaService;
  let server: E2eApp['server'];

  const suffix = Date.now();
  const PASSWORD = 'MotDePasseTemp1!';
  const userIds: string[] = [];
  const productIds: string[] = [];
  const customerIds: string[] = [];
  let token = '';
  let magasinId = '';

  const post = (url: string) =>
    request(server).post(url).set('Authorization', `Bearer ${token}`);

  const product = async (stock: string) => {
    const detail = await prisma.priceTier.findUniqueOrThrow({
      where: { code: 'DETAIL' },
    });
    const created = await prisma.product.create({
      data: {
        sku: `E2E-CONC-${randomUUID()}`,
        barcode: `E2E-CONC-BC-${randomUUID()}`,
        name: 'Produit concurrence',
        prices: { create: [{ priceTierId: detail.id, priceHt: 100000 }] },
      },
    });
    productIds.push(created.id);
    await prisma.stock.create({
      data: { productId: created.id, locationId: magasinId, quantity: stock },
    });
    return created.id;
  };

  beforeAll(async () => {
    e2e = await createE2eApp();
    prisma = e2e.prisma;
    server = e2e.server;
    magasinId = (
      await prisma.location.findFirstOrThrow({ where: { type: 'MAGASIN' } })
    ).id;
    const email = `e2e-conc-${suffix}@test.local`;
    const user = await createTestUser(prisma, {
      email,
      password: PASSWORD,
      roles: [RoleCode.ADMIN],
    });
    userIds.push(user.id);
    token = (
      await request(server)
        .post('/api/auth/login')
        .send({ identifier: email, password: PASSWORD })
        .expect(200)
    ).body.accessToken;
  });

  afterAll(async () => {
    const sales = await prisma.sale.findMany({
      where: { userId: { in: userIds } },
      select: { id: true },
    });
    await prisma.auditLog.deleteMany({ where: { userId: { in: userIds } } });
    await prisma.syncMutation.deleteMany({
      where: { userId: { in: userIds } },
    });
    await prisma.cashMovement.deleteMany({
      where: { userId: { in: userIds } },
    });
    await prisma.customerPayment.deleteMany({
      where: { customerId: { in: customerIds } },
    });
    await prisma.sale.deleteMany({
      where: { id: { in: sales.map((s) => s.id) } },
    });
    await prisma.cashSession.deleteMany({ where: { userId: { in: userIds } } });
    await prisma.stockLossDeclaration.deleteMany({
      where: { productId: { in: productIds } },
    });
    await prisma.stockMovement.deleteMany({
      where: { productId: { in: productIds } },
    });
    await prisma.stock.deleteMany({ where: { productId: { in: productIds } } });
    await prisma.product.deleteMany({ where: { id: { in: productIds } } });
    await prisma.customer.deleteMany({ where: { id: { in: customerIds } } });
    await prisma.user.deleteMany({ where: { id: { in: userIds } } });
    await e2e.app.close();
  });

  it('deux règlements simultanés (clés différentes) ne soldent pas deux fois la même dette', async () => {
    const p = await product('10');
    const customer = await prisma.customer.create({
      data: { name: `Client concurrence ${suffix}`, creditLimit: 1_000_000 },
    });
    customerIds.push(customer.id);
    await post('/api/sales')
      .send({
        customerId: customer.id,
        lines: [{ productId: p, quantity: '1' }],
        paidAmount: 0,
        dueDate: '2099-01-01',
      })
      .expect(201);
    const cash = await post('/api/cash-sessions')
      .send({ locationId: magasinId, openingFloat: 0 })
      .expect(201);

    const pay = () =>
      post('/api/payments/customer').send({
        customerId: customer.id,
        amount: 100000,
      });
    const results = await Promise.all([pay(), pay()]);
    expect(results.map((r) => r.status).sort()).toEqual([201, 422]);
    await post(`/api/cash-sessions/${cash.body.id}/close`)
      .send({ countedAmount: 100000 })
      .expect(200);
  });

  it('clôture de caisse PENDANT des ventes : le rapport Z compte exactement ce qui est entré', async () => {
    const p = await product('100');
    const cash = await post('/api/cash-sessions')
      .send({ locationId: magasinId, openingFloat: 10000 })
      .expect(201);

    const sale = () =>
      post('/api/sales').send({
        lines: [{ productId: p, quantity: '1' }],
        paidAmount: 100000,
      });
    const [z, ...sales] = await Promise.all([
      post(`/api/cash-sessions/${cash.body.id}/close`).send({
        countedAmount: 0,
      }),
      sale(),
      sale(),
      sale(),
    ]);
    expect(z.status).toBe(200);
    // Chaque vente passe AVANT la clôture (comptée) ou APRÈS (refusée faute de caisse).
    for (const s of sales) {
      expect([201, 422]).toContain(s.status);
    }
    const inSession = await prisma.cashMovement.aggregate({
      where: { cashSessionId: cash.body.id, type: 'VENTE_ESPECES' },
      _sum: { amount: true },
    });
    expect(z.body.expectedAmount).toBe(10000 + (inSession._sum.amount ?? 0));
    const accepted = sales.filter((s) => s.status === 201).length;
    expect(inSession._sum.amount ?? 0).toBe(accepted * 100000);
    // Aucune vente acceptée n'est rattachée à une caisse clôturée « après coup ».
    const late = await prisma.cashMovement.count({
      where: {
        cashSessionId: cash.body.id,
        createdAt: { gt: new Date(z.body.closedAt) },
      },
    });
    expect(late).toBe(0);
  });

  it('changement d’année pendant la numérotation : compteurs indépendants, sans trou ni doublon', async () => {
    // Années fictives : aucun conflit avec les vrais compteurs.
    const numberFor = (year: number) =>
      prisma.$transaction((tx) =>
        nextDocumentNumber(tx, 'DEVIS', 'DEV', 5, year),
      );
    const numbers = await Promise.all([
      ...Array.from({ length: 5 }, () => numberFor(2098)),
      ...Array.from({ length: 5 }, () => numberFor(2099)),
    ]);
    for (const year of [2098, 2099]) {
      const seq = numbers
        .filter((n) => n.startsWith(`DEV-${year}-`))
        .map((n) => Number(n.slice(-5)))
        .sort((a, b) => a - b);
      expect(seq).toEqual([1, 2, 3, 4, 5]);
    }
    await prisma.invoiceCounter.deleteMany({
      where: { documentType: 'DEVIS', year: { in: [2098, 2099] } },
    });
  });

  it('deux mutations offline concurrentes sur le même stock : jamais de stock négatif', async () => {
    const p = await product('5');
    const loss = () => ({
      clientMutationId: randomUUID(),
      deviceId: randomUUID(),
      operationType: 'MANUAL',
      deviceTimestamp: new Date().toISOString(),
      payload: {
        productId: p,
        locationId: magasinId,
        quantity: '5.000',
        type: 'PERTE_CASSE',
      },
    });
    const push = () => post('/api/sync').send({ mutations: [loss()] });
    const [a, b] = await Promise.all([push(), push()]);
    const statuses = [
      a.body.results[0].status,
      b.body.results[0].status,
    ].sort();
    expect(statuses).toEqual(['CONFIRMEE', 'REJETEE']);

    const stock = await prisma.stock.findFirstOrThrow({
      where: { productId: p, locationId: magasinId },
    });
    expect(stock.quantity.toFixed(3)).toBe('0.000');
  });
});
