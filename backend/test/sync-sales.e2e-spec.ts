import { randomUUID } from 'crypto';
import * as request from 'supertest';
import { RoleCode } from '../src/common/auth.decorators';
import { localDate } from '../src/common/document-number';
import { PrismaService } from '../src/prisma/prisma.service';
import { createE2eApp, createTestUser, E2eApp } from './helpers/e2e-app';
import { authorOf } from './helpers/sync-author';

/// Vente hors-ligne (P0 #12 tranche B) : le handler `SALE` applique le MÊME cœur
/// que `POST /sales`, et RECONNAÎT une vente déjà créée en ligne sous la clé.
describe('Vente hors-ligne par /sync (e2e)', () => {
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
  let detailId = '';
  let tva19Id = '';
  let counter = 0;
  /// Caisse ouverte du vendeur principal — portée par chacune de ses ventes.
  let cashSessionId = '';
  let closedSessionId = '';

  /// 1 450,00 HT, TVA 19 % : une unité = 1 725,50 TTC.
  const UNIT_TTC = 172550;

  const product = async (stock: string) => {
    const n = ++counter;
    const created = await prisma.product.create({
      data: {
        sku: `E2E-SYNCSALE-${suffix}-${n}`,
        barcode: `E2E-SYNCSALE-BC-${suffix}-${n}`,
        name: `Produit vente hors-ligne ${n}`,
        taxRateId: tva19Id,
        prices: { create: [{ priceTierId: detailId, priceHt: 145000 }] },
      },
    });
    productIds.push(created.id);
    await prisma.stock.create({
      data: { productId: created.id, locationId: magasinId, quantity: stock },
    });
    return created.id;
  };

  const stockOf = async (productId: string) =>
    (
      await prisma.stock.findUniqueOrThrow({
        where: { productId_locationId: { productId, locationId: magasinId } },
      })
    ).quantity.toFixed(3);

  /// Corps de vente — le MÊME pour la route en ligne et la file.
  const saleBody = (
    productId: string,
    over: Record<string, unknown> = {},
  ): Record<string, unknown> => ({
    clientMutationId: randomUUID(),
    id: randomUUID(),
    lines: [{ productId, quantity: '1.000' }],
    paidAmount: UNIT_TTC,
    expectedTotalTtc: UNIT_TTC,
    cashSessionId,
    ...over,
  });

  const mutation = (
    payload: Record<string, unknown>,
    over: Record<string, unknown> = {},
  ) => ({
    clientMutationId: payload.clientMutationId,
    deviceId: 'e2e-caisse',
    operationType: 'SALE',
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

  const salesWithKey = (clientMutationId: unknown) =>
    prisma.sale.count({
      where: { clientMutationId: String(clientMutationId) },
    });

  beforeAll(async () => {
    e2e = await createE2eApp();
    prisma = e2e.prisma;
    server = e2e.server;
    magasinId = (
      await prisma.location.findFirstOrThrow({ where: { type: 'MAGASIN' } })
    ).id;
    detailId = (
      await prisma.priceTier.findUniqueOrThrow({ where: { code: 'DETAIL' } })
    ).id;
    tva19Id = (await prisma.taxRate.findFirstOrThrow({ where: { rate: 19 } }))
      .id;
    for (const [key, role] of [
      ['vendeur', RoleCode.VENDEUR],
      ['vendeurSansCaisse', RoleCode.VENDEUR],
      ['vendeurCaisseRecente', RoleCode.VENDEUR],
      ['magasinier', RoleCode.MAGASINIER],
    ] as const) {
      const email = `e2e-syncsale-${key}-${suffix}@test.local`;
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
    const open = async (key: string): Promise<string> =>
      (
        await request(server)
          .post('/api/cash-sessions')
          .set('Authorization', `Bearer ${tokens[key]}`)
          .send({ locationId: magasinId, openingFloat: 0 })
          .expect(201)
      ).body.id;
    cashSessionId = await open('vendeur');
    // Second vendeur : une caisse CLÔTURÉE puis une nouvelle, ouverte.
    closedSessionId = await open('vendeurCaisseRecente');
    await request(server)
      .post(`/api/cash-sessions/${closedSessionId}/close`)
      .set('Authorization', `Bearer ${tokens.vendeurCaisseRecente}`)
      .send({ countedAmount: 0 })
      .expect(200);
    await open('vendeurCaisseRecente');
  });

  afterAll(async () => {
    const sales = await prisma.sale.findMany({
      where: { userId: { in: userIds } },
      select: { id: true },
    });
    const saleIds = sales.map((s) => s.id);
    await prisma.auditLog.deleteMany({
      where: {
        OR: [{ entityId: { in: saleIds } }, { userId: { in: userIds } }],
      },
    });
    await prisma.auditLog.deleteMany({
      where: { entityType: 'SyncMutation', userId: { in: userIds } },
    });
    await prisma.syncMutation.deleteMany({
      where: { userId: { in: userIds } },
    });
    await prisma.cashMovement.deleteMany({
      where: { userId: { in: userIds } },
    });
    await prisma.sale.deleteMany({ where: { id: { in: saleIds } } });
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

  it('ticket hors-ligne : CONFIRMEE, stock sorti, espèces en caisse, datée de l’appareil', async () => {
    const p = await product('5.000');
    const body = saleBody(p);
    const m = mutation(body);
    const res = await sync(tokens.vendeur, [m]);

    expect(res.body.results[0]).toMatchObject({
      status: 'CONFIRMEE',
      entityId: body.id,
      alreadyProcessed: false,
    });
    expect(res.body.results[0].serverState.number).toMatch(/^TK-\d{4}-\d{6}$/);
    expect(await stockOf(p)).toBe('4.000');
    const sale = await prisma.sale.findUniqueOrThrow({
      where: { id: String(body.id) },
    });
    expect(sale).toMatchObject({
      type: 'TICKET',
      totalTtc: UNIT_TTC,
      paidAmount: UNIT_TTC,
    });
    expect(sale.cashSessionId).not.toBeNull();
    expect(sale.soldAt.toISOString()).toBe(m.deviceTimestamp);
  });

  it('renvoi du même lot : rien n’est refait', async () => {
    const p = await product('5.000');
    const body = saleBody(p);
    await sync(tokens.vendeur, [mutation(body)]);
    const again = await sync(tokens.vendeur, [mutation(body)]);

    expect(again.body.results[0]).toMatchObject({
      status: 'CONFIRMEE',
      alreadyProcessed: true,
    });
    expect(await salesWithKey(body.clientMutationId)).toBe(1);
    expect(await stockOf(p)).toBe('4.000');
  });

  it('vente créée EN LIGNE (réponse perdue) puis même clé par la file : reconnue, pas refaite', async () => {
    const p = await product('5.000');
    const body = saleBody(p);
    await request(server)
      .post('/api/sales')
      .set('Authorization', `Bearer ${tokens.vendeur}`)
      .send(body)
      .expect(201);

    const res = await sync(tokens.vendeur, [mutation(body)]);

    expect(res.body.results[0]).toMatchObject({
      status: 'CONFIRMEE',
      entityId: body.id,
    });
    expect(await salesWithKey(body.clientMutationId)).toBe(1);
    expect(await stockOf(p)).toBe('4.000');
    expect(
      await prisma.cashMovement.count({ where: { saleId: String(body.id) } }),
    ).toBe(1);
  });

  it('même clé qu’une vente en ligne mais AUTRE panier : REJETEE, rien refait', async () => {
    const p = await product('5.000');
    const body = saleBody(p);
    await request(server)
      .post('/api/sales')
      .set('Authorization', `Bearer ${tokens.vendeur}`)
      .send(body)
      .expect(201);

    const res = await sync(tokens.vendeur, [
      mutation({
        ...body,
        lines: [{ productId: p, quantity: '2.000' }],
        paidAmount: 2 * UNIT_TTC,
        expectedTotalTtc: 2 * UNIT_TTC,
      }),
    ]);

    expect(res.body.results[0]).toMatchObject({
      status: 'REJETEE',
      code: 'SALE_ALREADY_RECORDED',
    });
    expect(await stockOf(p)).toBe('4.000');
  });

  it('stock insuffisant au moment du sync : REJETEE, rien écrit (règle 9)', async () => {
    const p = await product('1.000');
    const body = saleBody(p, {
      lines: [{ productId: p, quantity: '2.000' }],
      paidAmount: 2 * UNIT_TTC,
      expectedTotalTtc: 2 * UNIT_TTC,
    });
    const res = await sync(tokens.vendeur, [mutation(body)]);

    expect(res.body.results[0].status).toBe('REJETEE');
    expect(res.body.results[0].code).toMatch(/^STOCK_/);
    expect(await salesWithKey(body.clientMutationId)).toBe(0);
    expect(await stockOf(p)).toBe('1.000');
  });

  it('prix changé pendant la coupure : REJETEE SALE_TOTAL_CHANGED, rien écrit', async () => {
    const p = await product('5.000');
    await prisma.productPrice.updateMany({
      where: { productId: p, priceTierId: detailId },
      data: { priceHt: 150000 },
    });
    const body = saleBody(p);
    const res = await sync(tokens.vendeur, [mutation(body)]);

    expect(res.body.results[0]).toMatchObject({
      status: 'REJETEE',
      code: 'SALE_TOTAL_CHANGED',
    });
    expect(await salesWithKey(body.clientMutationId)).toBe(0);
    expect(await stockOf(p)).toBe('5.000');
  });

  it('total annoncé absent : REJETEE (le prix n’est jamais cru sur parole)', async () => {
    const p = await product('5.000');
    const body = saleBody(p);
    delete body.expectedTotalTtc;
    const res = await sync(tokens.vendeur, [mutation(body)]);

    expect(res.body.results[0]).toMatchObject({
      status: 'REJETEE',
      code: 'VALIDATION_FAILED',
    });
    expect(await stockOf(p)).toBe('5.000');
  });

  it('clé du corps ≠ clé de la mutation : REJETEE', async () => {
    const p = await product('5.000');
    const body = saleBody(p);
    const res = await sync(tokens.vendeur, [
      mutation(body, { clientMutationId: randomUUID() }),
    ]);

    expect(res.body.results[0]).toMatchObject({
      status: 'REJETEE',
      code: 'VALIDATION_FAILED',
    });
    expect(await stockOf(p)).toBe('5.000');
  });

  it('MAGASINIER : refusé comme en ligne', async () => {
    const p = await product('5.000');
    const res = await sync(tokens.magasinier, [mutation(saleBody(p))]);

    expect(res.body.results[0]).toMatchObject({
      status: 'REJETEE',
      code: 'FORBIDDEN_ROLE',
    });
    expect(await stockOf(p)).toBe('5.000');
  });

  it('espèces sans caisse ouverte : REJETEE CASH_SESSION_REQUIRED (règle 12)', async () => {
    const p = await product('5.000');
    const res = await sync(tokens.vendeurSansCaisse, [mutation(saleBody(p))]);

    expect(res.body.results[0]).toMatchObject({
      status: 'REJETEE',
      code: 'CASH_SESSION_REQUIRED',
    });
    expect(await stockOf(p)).toBe('5.000');
  });

  it.each([
    ['en avance (dans la tolérance du contrat)', 3600_000],
    ['trop ancienne (au-delà de 72 h hors-ligne)', -100 * 3600_000],
  ])(
    'horloge de l’appareil %s : la vente est datée du serveur',
    async (_label, offset) => {
      const p = await product('5.000');
      const body = saleBody(p);
      const before = Date.now();
      await sync(tokens.vendeur, [
        mutation(body, {
          deviceTimestamp: new Date(Date.now() + offset).toISOString(),
        }),
      ]);
      const sale = await prisma.sale.findUniqueOrThrow({
        where: { id: String(body.id) },
      });
      expect(sale.soldAt.getTime()).toBeGreaterThanOrEqual(before - 1000);
      expect(sale.soldAt.getTime()).toBeLessThanOrEqual(Date.now() + 1000);
    },
  );

  it('espèces d’une caisse CLÔTURÉE depuis : REJETEE CASH_SESSION_CLOSED, tracée pour l’admin', async () => {
    const p = await product('5.000');
    const body = saleBody(p, { cashSessionId: closedSessionId });
    const res = await sync(tokens.vendeurCaisseRecente, [mutation(body)]);

    expect(res.body.results[0]).toMatchObject({
      status: 'REJETEE',
      code: 'CASH_SESSION_CLOSED',
    });
    expect(await stockOf(p)).toBe('5.000');
    const audit = await prisma.auditLog.findFirst({
      where: {
        entityType: 'SyncMutation',
        entityId: String(body.clientMutationId),
      },
    });
    expect(audit).toMatchObject({ action: 'REJECT' });
    expect(audit?.newValue).toMatchObject({
      operationType: 'SALE',
      code: 'CASH_SESSION_CLOSED',
    });
  });

  it('crédit hors-ligne : l’échéance est jugée au jour de la VENTE, pas de la synchro', async () => {
    const p = await product('5.000');
    const customer = await prisma.customer.create({
      data: { name: `Client sync ${suffix}`, creditLimit: 10 * UNIT_TTC },
    });
    customerIds.push(customer.id);
    const soldAt = new Date(Date.now() - 50 * 3600_000);
    const body = saleBody(p, {
      customerId: customer.id,
      paidAmount: 0,
      dueDate: localDate(soldAt),
    });
    const res = await sync(tokens.vendeur, [
      mutation(body, { deviceTimestamp: soldAt.toISOString() }),
    ]);

    expect(res.body.results[0].status).toBe('CONFIRMEE');
    expect(await stockOf(p)).toBe('4.000');
  });

  it('vente EN LIGNE et même vente par /sync en même temps : jamais de rejet ni de doublon', async () => {
    const p = await product('5.000');
    const body = saleBody(p);
    const [online, synced] = await Promise.all([
      request(server)
        .post('/api/sales')
        .set('Authorization', `Bearer ${tokens.vendeur}`)
        .send(body),
      sync(tokens.vendeur, [mutation(body)]),
    ]);

    expect([200, 201, 409]).toContain(online.status);
    expect(['CONFIRMEE', 'NON_TRAITEE']).toContain(
      synced.body.results[0].status,
    );
    // Le cycle suivant tranche : la vente est reconnue.
    const again = await sync(tokens.vendeur, [mutation(body)]);
    expect(again.body.results[0].status).toBe('CONFIRMEE');
    expect(await salesWithKey(body.clientMutationId)).toBe(1);
    expect(await stockOf(p)).toBe('4.000');
  });

  it('remise envoyée par un VENDEUR : REJETEE, rien écrit', async () => {
    const p = await product('5.000');
    const res = await sync(tokens.vendeur, [
      mutation(
        saleBody(p, {
          lines: [{ productId: p, quantity: '1.000', discountAmount: 100 }],
        }),
      ),
    ]);
    expect(res.body.results[0]).toMatchObject({
      status: 'REJETEE',
      code: 'DISCOUNT_NOT_ALLOWED',
    });
    expect(await stockOf(p)).toBe('5.000');
  });

  it('prix, type ou numéro forgés dans le corps : REJETEE (champs inconnus)', async () => {
    const p = await product('5.000');
    for (const forged of [
      { lines: [{ productId: p, quantity: '1.000', unitPriceHt: 1 }] },
      { type: 'FACTURE' },
      { invoiceNumber: 'FA-2026-000001' },
      { soldAt: '2020-01-01T00:00:00.000Z' },
    ]) {
      const res = await sync(tokens.vendeur, [mutation(saleBody(p, forged))]);
      expect(res.body.results[0]).toMatchObject({
        status: 'REJETEE',
        code: 'VALIDATION_FAILED',
      });
    }
    expect(await stockOf(p)).toBe('5.000');
  });

  it('clé de la vente d’un AUTRE compte : refusée sans en révéler le numéro ni le total', async () => {
    const p = await product('5.000');
    const body = saleBody(p);
    await sync(tokens.vendeur, [mutation(body)]);
    const res = await sync(tokens.vendeurCaisseRecente, [
      mutation(body, { deviceTimestamp: new Date().toISOString() }),
    ]);

    expect(res.body.results[0].status).toBe('REJETEE');
    expect(JSON.stringify(res.body)).not.toMatch(/TK-\d{4}/);
    expect(JSON.stringify(res.body)).not.toMatch(/1\s?725,50/);
    expect(await stockOf(p)).toBe('4.000');
  });

  it('espèces sans caisse désignée : REJETEE (jamais imputées à la caisse du moment)', async () => {
    const p = await product('5.000');
    const body = saleBody(p);
    delete body.cashSessionId;
    const res = await sync(tokens.vendeur, [mutation(body)]);
    expect(res.body.results[0]).toMatchObject({
      status: 'REJETEE',
      code: 'VALIDATION_FAILED',
    });
    expect(await stockOf(p)).toBe('5.000');
  });

  it('refus d’ACCÈS : pas d’entrée d’audit (anti-inondation de l’Historique)', async () => {
    const p = await product('5.000');
    const body = saleBody(p);
    await sync(tokens.magasinier, [mutation(body)]);
    expect(
      await prisma.auditLog.count({
        where: { entityId: String(body.clientMutationId) },
      }),
    ).toBe(0);
  });
});
