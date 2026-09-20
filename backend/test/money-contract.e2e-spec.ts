import { randomUUID } from 'crypto';
import * as request from 'supertest';
import { RoleCode } from '../src/common/auth.decorators';
import { PrismaService } from '../src/prisma/prisma.service';
import { createE2eApp, createTestUser, E2eApp } from './helpers/e2e-app';
import { MONEY_ROUTES } from './money-routes';

/// Contrats TRANSVERSAUX des mutations d'argent (revue générale 2026-09-16) :
/// 1. idempotence : TOUTE mutation d'argent exige un `clientMutationId` ; un
///    renvoi (même simultané) n'applique jamais un second effet ;
/// 2. caisse : AUCUNE sortie ne rend une session négative, quel que soit le chemin.
/// Échéance lointaine pour les ventes à crédit des tests (obligatoire).
const DUE_DATE = '2099-12-31';

describe('Contrats argent : idempotence et caisse (e2e)', () => {
  let e2e: E2eApp;
  let prisma: PrismaService;
  let server: E2eApp['server'];

  const suffix = Date.now();
  const PASSWORD = 'MotDePasseTemp1!';
  const userIds: string[] = [];
  const productIds: string[] = [];
  const customerIds: string[] = [];
  const supplierIds: string[] = [];
  let token = '';
  let magasinId = '';
  let productId = '';

  const post = (url: string) =>
    request(server).post(url).set('Authorization', `Bearer ${token}`);
  const get = (url: string) =>
    request(server).get(url).set('Authorization', `Bearer ${token}`);

  beforeAll(async () => {
    e2e = await createE2eApp();
    prisma = e2e.prisma;
    server = e2e.server;
    magasinId = (
      await prisma.location.findFirstOrThrow({ where: { type: 'MAGASIN' } })
    ).id;
    const email = `e2e-money-${suffix}@test.local`;
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

    const detail = await prisma.priceTier.findUniqueOrThrow({
      where: { code: 'DETAIL' },
    });
    const product = await prisma.product.create({
      data: {
        sku: `E2E-MONEY-${suffix}`,
        barcode: `E2E-MONEY-BC-${suffix}`,
        name: 'Produit contrat argent',
        prices: { create: [{ priceTierId: detail.id, priceHt: 100000 }] },
      },
    });
    productIds.push(product.id);
    productId = product.id;
    await prisma.stock.create({
      data: { productId, locationId: magasinId, quantity: '100' },
    });
  });

  afterAll(async () => {
    const sales = await prisma.sale.findMany({
      where: { userId: { in: userIds } },
      select: { id: true },
    });
    await prisma.auditLog.deleteMany({ where: { userId: { in: userIds } } });
    await prisma.cashMovement.deleteMany({
      where: { userId: { in: userIds } },
    });
    await prisma.customerPayment.deleteMany({
      where: { customerId: { in: customerIds } },
    });
    await prisma.supplierPayment.deleteMany({
      where: { supplierId: { in: supplierIds } },
    });
    await prisma.sale.deleteMany({
      where: { id: { in: sales.map((s) => s.id) } },
    });
    await prisma.cashSession.deleteMany({ where: { userId: { in: userIds } } });
    await prisma.stockMovement.deleteMany({
      where: { productId: { in: productIds } },
    });
    await prisma.stock.deleteMany({ where: { productId: { in: productIds } } });
    await prisma.product.deleteMany({ where: { id: { in: productIds } } });
    await prisma.customer.deleteMany({ where: { id: { in: customerIds } } });
    await prisma.supplier.deleteMany({ where: { id: { in: supplierIds } } });
    await prisma.user.deleteMany({ where: { id: { in: userIds } } });
    await e2e.app.close();
  });

  it('clé absente → 400 sur CHAQUE mutation d’argent', async () => {
    // Corps envoyé en chaîne JSON : l'aide de test n'y ajoute pas de clé.
    const raw = (url: string, body: object) =>
      post(url)
        .set('Content-Type', 'application/json')
        .send(JSON.stringify(body));
    const zero = '00000000-0000-4000-8000-000000000000';
    // Corps par route, pour CHAQUE route d'argent de la liste partagée : en
    // ajouter une sans corps ici fait échouer le test (aucune ne peut être oubliée).
    const bodies: Record<(typeof MONEY_ROUTES)[number], object> = {
      '/api/sales': { lines: [{ productId, quantity: '1' }], paidAmount: 0 },
      '/api/cash-sessions': { locationId: magasinId, openingFloat: 0 },
      '/api/cash-sessions/:id/close': { countedAmount: 0 },
      '/api/payments/customer': { customerId: zero, amount: 1 },
      '/api/payments/customer/:id/reverse': { reason: 'Erreur' },
      '/api/payments/supplier': {
        supplierId: zero,
        amount: 1,
        fromCash: false,
      },
      '/api/payments/supplier/:id/reverse': { reason: 'Erreur' },
      '/api/receptions': {
        supplierId: zero,
        locationId: magasinId,
        lines: [{ productId, receivedQuantity: '1', unitPriceHt: 1 }],
      },
    };
    for (const route of MONEY_ROUTES) {
      const url = route.replace(/:[^/]+/g, zero);
      const body = bodies[route];
      {
        const res = await raw(url, body).expect(400);
        expect({
          url,
          message: JSON.stringify(res.body.message),
        }).toMatchObject({
          url,
          message: expect.stringContaining(
            'clientMutationId',
          ) as unknown as string,
        });
      }
    }
  });

  it('caisse : ouverture et clôture rejouées → une seule session, un seul rapport Z', async () => {
    const openKey = randomUUID();
    const open = {
      clientMutationId: openKey,
      locationId: magasinId,
      openingFloat: 50000,
    };
    const first = await post('/api/cash-sessions').send(open).expect(201);
    const again = await post('/api/cash-sessions').send(open).expect(201);
    expect(again.body.id).toBe(first.body.id);
    // Même clé, autre fond : ce n'est pas un renvoi.
    await post('/api/cash-sessions')
      .send({ ...open, openingFloat: 99 })
      .expect(409);

    const close = { clientMutationId: randomUUID(), countedAmount: 50000 };
    const z1 = await post(`/api/cash-sessions/${first.body.id}/close`)
      .send(close)
      .expect(200);
    const z2 = await post(`/api/cash-sessions/${first.body.id}/close`)
      .send(close)
      .expect(200);
    expect(z2.body.closedAt).toBe(z1.body.closedAt);
    await post(`/api/cash-sessions/${first.body.id}/close`)
      .send({ ...close, countedAmount: 1 })
      .expect(409);
    expect(
      await prisma.auditLog.count({
        where: { entityId: first.body.id, action: 'VALIDATE' },
      }),
    ).toBe(1);
  });

  it('règlement client envoyé DEUX FOIS EN MÊME TEMPS avec la même clé : une seule dette réduite', async () => {
    const customer = await prisma.customer.create({
      data: { name: `Client contrat ${suffix}`, creditLimit: 1000000 },
    });
    customerIds.push(customer.id);
    const cash = await post('/api/cash-sessions')
      .send({ locationId: magasinId, openingFloat: 0 })
      .expect(201);
    await post('/api/sales')
      .send({
        customerId: customer.id,
        lines: [{ productId, quantity: '1' }],
        paidAmount: 0,
        dueDate: DUE_DATE,
      })
      .expect(201);

    const body = {
      clientMutationId: randomUUID(),
      customerId: customer.id,
      amount: 40000,
    };
    const results = await Promise.all([
      post('/api/payments/customer').send(body),
      post('/api/payments/customer').send(body),
    ]);
    expect(results.map((r) => r.status)).toEqual([201, 201]);
    expect(results[0].body.id).toBe(results[1].body.id);
    expect(
      await prisma.customerPayment.count({
        where: { customerId: customer.id },
      }),
    ).toBe(1);
    await post(`/api/cash-sessions/${cash.body.id}/close`)
      .send({ countedAmount: 40000 })
      .expect(200);
  });

  it('annuler une vente ne rend JAMAIS la caisse négative (garde commun avec les fournisseurs)', async () => {
    const supplier = await prisma.supplier.create({
      data: { name: `Fournisseur contrat ${suffix}`, openingBalance: 1000000 },
    });
    supplierIds.push(supplier.id);
    const cash = await post('/api/cash-sessions')
      .send({ locationId: magasinId, openingFloat: 0 })
      .expect(201);
    // Vente de 1 000,00 encaissée, puis le tiroir est vidé par un paiement fournisseur.
    const sale = (
      await post('/api/sales')
        .send({ lines: [{ productId, quantity: '1' }], paidAmount: 100000 })
        .expect(201)
    ).body;
    await post('/api/payments/supplier')
      .send({ supplierId: supplier.id, amount: 100000, fromCash: true })
      .expect(201);

    const refused = await post(`/api/sales/${sale.id}/cancel`).expect(422);
    expect(refused.body.code).toBe('CASH_INSUFFICIENT');

    // Rien n'a bougé : vente toujours valide, tiroir à zéro (jamais négatif).
    expect((await get(`/api/sales/${sale.id}`).expect(200)).body.status).toBe(
      'VALIDEE',
    );
    const report = await get(
      `/api/cash-sessions/${cash.body.id}/report`,
    ).expect(200);
    expect(report.body.currentAmount).toBe(0);
    await post(`/api/cash-sessions/${cash.body.id}/close`)
      .send({ countedAmount: 0 })
      .expect(200);
  });
});
