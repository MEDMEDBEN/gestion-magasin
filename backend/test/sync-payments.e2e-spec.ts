import { randomUUID } from 'crypto';
import * as request from 'supertest';
import { AuthenticatedUser, RoleCode } from '../src/common/auth.decorators';
import { CustomersService } from '../src/customers/customers.service';
import { CreateCustomerPaymentDto } from '../src/customers/dto/customer.dto';
import { PrismaService } from '../src/prisma/prisma.service';
import { createE2eApp, createTestUser, E2eApp } from './helpers/e2e-app';
import { authorOf } from './helpers/sync-author';

/// Règlement client hors-ligne (P0 #12 tranche E) : même cœur que
/// `POST /payments/customer`, caisse du règlement obligatoire, reconnaissance
/// d'un règlement déjà fait en ligne sous la même clé.
describe('Règlement client hors-ligne par /sync (e2e)', () => {
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
  let cashSessionId = '';
  let closedSessionId = '';
  let counter = 0;

  /// 1 450,00 HT, TVA 19 % : une unité = 1 725,50 TTC.
  const UNIT_TTC = 172550;

  const as = (token: string) => ({
    post: (url: string) =>
      request(server).post(url).set('Authorization', `Bearer ${token}`),
  });

  /// Client qui doit UNE vente à crédit de 1 725,50.
  const indebtedCustomer = async (): Promise<string> => {
    const n = ++counter;
    const tier = await prisma.priceTier.findUniqueOrThrow({
      where: { code: 'DETAIL' },
    });
    const tva = await prisma.taxRate.findFirstOrThrow({ where: { rate: 19 } });
    const product = await prisma.product.create({
      data: {
        sku: `E2E-SYNCPAY-${suffix}-${n}`,
        barcode: `E2E-SYNCPAY-BC-${suffix}-${n}`,
        name: `Produit règlement ${n}`,
        taxRateId: tva.id,
        prices: { create: [{ priceTierId: tier.id, priceHt: 145000 }] },
      },
    });
    productIds.push(product.id);
    await prisma.stock.create({
      data: { productId: product.id, locationId: magasinId, quantity: '5' },
    });
    const customer = await prisma.customer.create({
      data: {
        name: `Client règlement ${suffix}-${n}`,
        creditLimit: 10_000_000,
      },
    });
    customerIds.push(customer.id);
    await as(tokens.vendeur)
      .post('/api/sales')
      .send({
        customerId: customer.id,
        lines: [{ productId: product.id, quantity: '1' }],
        paidAmount: 0,
        dueDate: '2099-12-31',
      })
      .expect(201);
    return customer.id;
  };

  const debtOf = async (customerId: string) =>
    (
      await request(server)
        .get(`/api/customers/${customerId}`)
        .set('Authorization', `Bearer ${tokens.vendeur}`)
        .expect(200)
    ).body.balanceDue as number;

  const body = (
    customerId: string,
    amount: number,
    over: Record<string, unknown> = {},
  ): Record<string, unknown> => ({
    clientMutationId: randomUUID(),
    id: randomUUID(),
    customerId,
    amount,
    cashSessionId,
    ...over,
  });

  const mutation = (
    payload: Record<string, unknown>,
    over: Record<string, unknown> = {},
  ) => ({
    clientMutationId: payload.clientMutationId,
    deviceId: 'e2e-caisse',
    operationType: 'CUSTOMER_PAYMENT',
    deviceTimestamp: new Date(Date.now() - 3600_000).toISOString(),
    payload,
    ...over,
  });

  const sync = (token: string, mutations: unknown[]) =>
    request(server)
      .post('/api/sync')
      .set('Authorization', `Bearer ${token}`)
      .send({ authorUserId: authorOf(token), mutations })
      .expect(200);

  const paymentsWithKey = (key: unknown) =>
    prisma.customerPayment.count({ where: { clientMutationId: String(key) } });

  beforeAll(async () => {
    e2e = await createE2eApp();
    prisma = e2e.prisma;
    server = e2e.server;
    magasinId = (
      await prisma.location.findFirstOrThrow({ where: { type: 'MAGASIN' } })
    ).id;
    for (const [key, role] of [
      ['vendeur', RoleCode.VENDEUR],
      ['vendeur2', RoleCode.VENDEUR],
      ['magasinier', RoleCode.MAGASINIER],
    ] as const) {
      const email = `e2e-syncpay-${key}-${suffix}@test.local`;
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
    const open = async () =>
      (
        await as(tokens.vendeur)
          .post('/api/cash-sessions')
          .send({ locationId: magasinId, openingFloat: 0 })
          .expect(201)
      ).body.id as string;
    // Une caisse CLÔTURÉE, puis la caisse ouverte des tests.
    closedSessionId = await open();
    await as(tokens.vendeur)
      .post(`/api/cash-sessions/${closedSessionId}/close`)
      .send({ countedAmount: 0 })
      .expect(200);
    cashSessionId = await open();
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
    await prisma.stockMovement.deleteMany({
      where: { productId: { in: productIds } },
    });
    await prisma.stock.deleteMany({ where: { productId: { in: productIds } } });
    await prisma.product.deleteMany({ where: { id: { in: productIds } } });
    await prisma.customer.deleteMany({ where: { id: { in: customerIds } } });
    await prisma.user.deleteMany({ where: { id: { in: userIds } } });
    await e2e.app.close();
  });

  it('règlement hors-ligne : CONFIRMEE, dette réduite, espèces dans la caisse du règlement', async () => {
    const customerId = await indebtedCustomer();
    const b = body(customerId, 50000);
    const res = await sync(tokens.vendeur, [mutation(b)]);

    expect(res.body.results[0]).toMatchObject({
      status: 'CONFIRMEE',
      entityId: b.id,
    });
    expect(await debtOf(customerId)).toBe(UNIT_TTC - 50000);
    const cash = await prisma.cashMovement.findFirstOrThrow({
      where: { note: { contains: String(b.id) } },
    });
    expect(cash).toMatchObject({ cashSessionId, amount: 50000 });
  });

  it('règlement fait EN LIGNE (réponse perdue) puis même clé par la file : reconnu, pas refait', async () => {
    const customerId = await indebtedCustomer();
    const b = body(customerId, 30000);
    await as(tokens.vendeur).post('/api/payments/customer').send(b).expect(201);

    const res = await sync(tokens.vendeur, [mutation(b)]);

    expect(res.body.results[0]).toMatchObject({
      status: 'CONFIRMEE',
      entityId: b.id,
    });
    expect(await paymentsWithKey(b.clientMutationId)).toBe(1);
    expect(await debtOf(customerId)).toBe(UNIT_TTC - 30000);
  });

  it('même règlement EN LIGNE et par /sync en même temps : jamais de faux rejet', async () => {
    const customerId = await indebtedCustomer();
    // Toute la dette : une seconde application serait « supérieure à la dette ».
    const b = body(customerId, UNIT_TTC);
    const [online, synced] = await Promise.all([
      as(tokens.vendeur).post('/api/payments/customer').send(b),
      sync(tokens.vendeur, [mutation(b)]),
    ]);

    expect([201, 409]).toContain(online.status);
    expect(['CONFIRMEE', 'NON_TRAITEE']).toContain(
      synced.body.results[0].status,
    );
    const again = await sync(tokens.vendeur, [mutation(b)]);
    expect(again.body.results[0].status).toBe('CONFIRMEE');
    expect(await paymentsWithKey(b.clientMutationId)).toBe(1);
    expect(await debtOf(customerId)).toBe(0);
  });

  it('règlement supérieur à la dette AU SYNC : REJETEE, rien encaissé', async () => {
    const customerId = await indebtedCustomer();
    const b = body(customerId, UNIT_TTC + 1);
    const res = await sync(tokens.vendeur, [mutation(b)]);

    expect(res.body.results[0]).toMatchObject({
      status: 'REJETEE',
      code: 'VALIDATION_FAILED',
    });
    expect(await debtOf(customerId)).toBe(UNIT_TTC);
  });

  it('espèces d’une caisse CLÔTURÉE depuis : REJETEE CASH_SESSION_CLOSED', async () => {
    const customerId = await indebtedCustomer();
    const res = await sync(tokens.vendeur, [
      mutation(body(customerId, 1000, { cashSessionId: closedSessionId })),
    ]);
    expect(res.body.results[0]).toMatchObject({
      status: 'REJETEE',
      code: 'CASH_SESSION_CLOSED',
    });
    expect(await debtOf(customerId)).toBe(UNIT_TTC);
  });

  it('caisse non désignée : REJETEE (jamais imputé à la caisse du moment)', async () => {
    const customerId = await indebtedCustomer();
    const b = body(customerId, 1000);
    delete b.cashSessionId;
    const res = await sync(tokens.vendeur, [mutation(b)]);
    expect(res.body.results[0]).toMatchObject({
      status: 'REJETEE',
      code: 'VALIDATION_FAILED',
    });
  });

  it('MAGASINIER : refusé comme en ligne', async () => {
    const customerId = await indebtedCustomer();
    const res = await sync(tokens.magasinier, [
      mutation(body(customerId, 1000)),
    ]);
    expect(res.body.results[0]).toMatchObject({
      status: 'REJETEE',
      code: 'FORBIDDEN_ROLE',
    });
    expect(await debtOf(customerId)).toBe(UNIT_TTC);
  });

  it('relu SOUS le verrou : le cœur rend le règlement déjà enregistré au lieu de le refuser', async () => {
    // Situation exacte de la course : la vérification AVANT le verrou n'a rien
    // vu, le même règlement s'est validé en ligne pendant l'attente.
    const customerId = await indebtedCustomer();
    const b = body(customerId, UNIT_TTC);
    await as(tokens.vendeur).post('/api/payments/customer').send(b).expect(201);

    const service = e2e.app.get(CustomersService);
    const user = {
      id: authorOf(tokens.vendeur),
      roles: [RoleCode.VENDEUR],
      permissions: ['customer.payment.create'],
    } as unknown as AuthenticatedUser;
    const again = await prisma.$transaction((tx) =>
      service.payInTx(tx, b as unknown as CreateCustomerPaymentDto, user, null),
    );

    expect(again.id).toBe(b.id);
    expect(await paymentsWithKey(b.clientMutationId)).toBe(1);
    expect(await debtOf(customerId)).toBe(0);
  });

  it('clé du règlement d’un AUTRE compte : REJETEE, rien encaissé deux fois', async () => {
    const customerId = await indebtedCustomer();
    const b = body(customerId, 10000);
    await sync(tokens.vendeur, [mutation(b)]);

    const res = await sync(tokens.vendeur2, [mutation(b)]);

    expect(res.body.results[0].status).toBe('REJETEE');
    expect(await debtOf(customerId)).toBe(UNIT_TTC - 10000);
  });
});
