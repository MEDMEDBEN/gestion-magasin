import { randomUUID } from 'crypto';
import * as request from 'supertest';
import { RoleCode } from '../src/common/auth.decorators';
import { PrismaService } from '../src/prisma/prisma.service';
import { createE2eApp, createTestUser, E2eApp } from './helpers/e2e-app';
import { authorOf } from './helpers/sync-author';

/// Réception hors-ligne (P0 #12 tranche D) : même cœur que `POST /receptions`,
/// et reconnaissance d'une réception déjà faite en ligne sous la même clé.
describe('Réception hors-ligne par /sync (e2e)', () => {
  let e2e: E2eApp;
  let prisma: PrismaService;
  let server: E2eApp['server'];

  const suffix = Date.now();
  const PASSWORD = 'MotDePasseTemp1!';
  const userIds: string[] = [];
  const productIds: string[] = [];
  const supplierIds: string[] = [];
  const orderIds: string[] = [];
  const tokens: Record<string, string> = {};
  let supplierId = '';
  let depotId = '';
  let counter = 0;

  const as = (token: string) => ({
    post: (url: string) =>
      request(server).post(url).set('Authorization', `Bearer ${token}`),
  });

  /// Commande CONFIRMÉE de `quantity` unités à 1 200,00 HT.
  const confirmedOrder = async (quantity = '10') => {
    const n = ++counter;
    const tva = await prisma.taxRate.findFirstOrThrow({ where: { rate: 19 } });
    const productId = (
      await prisma.product.create({
        data: {
          sku: `E2E-SYNCBR-${suffix}-${n}`,
          barcode: `E2E-SYNCBR-BC-${suffix}-${n}`,
          name: `Produit réception hors-ligne ${n}`,
          taxRateId: tva.id,
        },
      })
    ).id;
    productIds.push(productId);
    const created = (
      await as(tokens.magasinier)
        .post('/api/purchase-orders')
        .send({
          supplierId,
          lines: [
            { productId, orderedQuantity: quantity, unitPriceHt: 120000 },
          ],
        })
        .expect(201)
    ).body;
    orderIds.push(created.id);
    const confirmed = (
      await as(tokens.admin)
        .post(`/api/purchase-orders/${created.id}/confirm`)
        .send({ expectedUpdatedAt: created.updatedAt })
        .expect(200)
    ).body;
    return {
      id: confirmed.id as string,
      productId,
      lineId: confirmed.lines[0].id as string,
    };
  };

  const body = (
    order: { id: string; productId: string; lineId: string },
    receivedQuantity = '4',
    over: Record<string, unknown> = {},
  ): Record<string, unknown> => ({
    clientMutationId: randomUUID(),
    id: randomUUID(),
    purchaseOrderId: order.id,
    supplierId,
    locationId: depotId,
    lines: [
      {
        productId: order.productId,
        purchaseLineId: order.lineId,
        receivedQuantity,
        // Obligatoire au contrat, IGNORÉ sur une ligne de commande (audit P0 #7).
        unitPriceHt: 120000,
      },
    ],
    ...over,
  });

  const mutation = (
    payload: Record<string, unknown>,
    over: Record<string, unknown> = {},
  ) => ({
    clientMutationId: payload.clientMutationId,
    deviceId: 'e2e-depot',
    operationType: 'RECEPTION',
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

  const stockOf = async (productId: string) =>
    (
      await prisma.stock.findFirst({
        where: { productId, locationId: depotId },
      })
    )?.quantity.toFixed(3) ?? '0.000';

  const receptionsWithKey = (key: unknown) =>
    prisma.reception.count({ where: { clientMutationId: String(key) } });

  beforeAll(async () => {
    e2e = await createE2eApp();
    prisma = e2e.prisma;
    server = e2e.server;
    for (const [key, role] of [
      ['admin', RoleCode.ADMIN],
      ['magasinier', RoleCode.MAGASINIER],
      ['vendeur', RoleCode.VENDEUR],
    ] as const) {
      const email = `e2e-syncbr-${key}-${suffix}@test.local`;
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
    const supplier = await prisma.supplier.create({
      data: { name: `Fournisseur réceptions hors-ligne ${suffix}` },
    });
    supplierIds.push(supplier.id);
    supplierId = supplier.id;
    depotId = (
      await prisma.location.findFirstOrThrow({ where: { type: 'DEPOT' } })
    ).id;
  });

  afterAll(async () => {
    const receptions = await prisma.reception.findMany({
      where: { supplierId: { in: supplierIds } },
      select: { id: true },
    });
    await prisma.auditLog.deleteMany({ where: { userId: { in: userIds } } });
    await prisma.syncMutation.deleteMany({
      where: { userId: { in: userIds } },
    });
    await prisma.receptionLine.deleteMany({
      where: { receptionId: { in: receptions.map((r) => r.id) } },
    });
    await prisma.reception.deleteMany({
      where: { id: { in: receptions.map((r) => r.id) } },
    });
    await prisma.purchaseOrder.deleteMany({ where: { id: { in: orderIds } } });
    await prisma.stockMovement.deleteMany({
      where: { productId: { in: productIds } },
    });
    await prisma.stock.deleteMany({ where: { productId: { in: productIds } } });
    await prisma.product.deleteMany({ where: { id: { in: productIds } } });
    await prisma.supplier.deleteMany({ where: { id: { in: supplierIds } } });
    await prisma.user.deleteMany({ where: { id: { in: userIds } } });
    await e2e.app.close();
  });

  it('réception hors-ligne : CONFIRMEE, stock +reçu, commande avancée, coût et date de l’appareil', async () => {
    const order = await confirmedOrder('10');
    const b = body(order, '4');
    const m = mutation(b);
    const res = await sync(tokens.magasinier, [m]);

    expect(res.body.results[0]).toMatchObject({
      status: 'CONFIRMEE',
      entityId: b.id,
    });
    expect(res.body.results[0].serverState.number).toMatch(/^BR-/);
    expect(await stockOf(order.productId)).toBe('4.000');
    const saved = await prisma.reception.findUniqueOrThrow({
      where: { id: String(b.id) },
    });
    expect(saved.receivedAt.toISOString()).toBe(m.deviceTimestamp);
    expect(
      (
        await prisma.purchaseOrder.findUniqueOrThrow({
          where: { id: order.id },
        })
      ).status,
    ).toBe('PARTIELLEMENT_RECUE');
    expect(
      (
        await prisma.product.findUniqueOrThrow({
          where: { id: order.productId },
        })
      ).lastPurchasePriceHt,
    ).toBe(120000);
  });

  it('réception faite EN LIGNE (réponse perdue) puis même clé par la file : reconnue, pas refaite', async () => {
    const order = await confirmedOrder('10');
    const b = body(order, '3');
    await as(tokens.magasinier).post('/api/receptions').send(b).expect(201);

    const res = await sync(tokens.magasinier, [mutation(b)]);

    expect(res.body.results[0]).toMatchObject({
      status: 'CONFIRMEE',
      entityId: b.id,
    });
    expect(await receptionsWithKey(b.clientMutationId)).toBe(1);
    expect(await stockOf(order.productId)).toBe('3.000');
  });

  it('surlivraison au moment du sync (autre réception passée entre-temps) : REJETEE, rien entré', async () => {
    const order = await confirmedOrder('10');
    await as(tokens.magasinier)
      .post('/api/receptions')
      .send(body(order, '8'))
      .expect(201);

    const b = body(order, '5');
    const res = await sync(tokens.magasinier, [mutation(b)]);

    expect(res.body.results[0].status).toBe('REJETEE');
    expect(await receptionsWithKey(b.clientMutationId)).toBe(0);
    expect(await stockOf(order.productId)).toBe('8.000');
  });

  it('prix d’achat forgé dans le corps : IGNORÉ, c’est celui de la COMMANDE qui fait foi', async () => {
    const order = await confirmedOrder('10');
    const b = body(order, '1');
    (b.lines as Record<string, unknown>[])[0].unitPriceHt = 1;
    const res = await sync(tokens.magasinier, [mutation(b)]);

    expect(res.body.results[0].status).toBe('CONFIRMEE');
    expect(
      (
        await prisma.product.findUniqueOrThrow({
          where: { id: order.productId },
        })
      ).lastPurchasePriceHt,
    ).toBe(120000);
  });

  it('hors commande par un MAGASINIER : REJETEE comme en ligne', async () => {
    const order = await confirmedOrder('10');
    const b = body(order, '1', { purchaseOrderId: undefined });
    (b.lines as Record<string, unknown>[])[0].purchaseLineId = undefined;
    const res = await sync(tokens.magasinier, [mutation(b)]);

    expect(res.body.results[0]).toMatchObject({
      status: 'REJETEE',
      code: 'FORBIDDEN_ROLE',
    });
    expect(await stockOf(order.productId)).toBe('0.000');
    // Refus d'une RÈGLE MÉTIER (pas d'un droit du moteur) : tracé pour
    // l'admin — la marchandise est peut-être déjà physiquement au dépôt.
    const audit = await prisma.auditLog.findFirst({
      where: {
        entityType: 'SyncMutation',
        entityId: String(b.clientMutationId),
      },
    });
    expect(audit?.action).toBe('REJECT');
  });

  it('VENDEUR : refusé comme en ligne', async () => {
    const order = await confirmedOrder('10');
    const res = await sync(tokens.vendeur, [mutation(body(order, '1'))]);
    expect(res.body.results[0]).toMatchObject({
      status: 'REJETEE',
      code: 'FORBIDDEN_ROLE',
    });
    expect(await stockOf(order.productId)).toBe('0.000');
  });

  it('clé du corps ≠ clé de la mutation : REJETEE', async () => {
    const order = await confirmedOrder('10');
    const b = body(order, '1');
    const res = await sync(tokens.magasinier, [
      mutation(b, { clientMutationId: randomUUID() }),
    ]);
    expect(res.body.results[0]).toMatchObject({
      status: 'REJETEE',
      code: 'VALIDATION_FAILED',
    });
    expect(await stockOf(order.productId)).toBe('0.000');
  });

  it('réception synchronisée TARD : elle n’écrase pas le coût d’une réception plus récente', async () => {
    const order = await confirmedOrder('10');
    // Faite hors-ligne il y a 1 h (1 200,00 HT, prix de la commande)…
    const late = body(order, '2');
    // …alors qu'entre-temps une réception en ligne a fixé un autre coût.
    await prisma.product.update({
      where: { id: order.productId },
      data: { lastPurchasePriceHt: 130000 },
    });
    await as(tokens.magasinier)
      .post('/api/receptions')
      .send(body(order, '1'))
      .expect(201);
    await prisma.product.update({
      where: { id: order.productId },
      data: { lastPurchasePriceHt: 130000 },
    });

    const res = await sync(tokens.magasinier, [mutation(late)]);

    expect(res.body.results[0].status).toBe('CONFIRMEE');
    expect(
      (
        await prisma.product.findUniqueOrThrow({
          where: { id: order.productId },
        })
      ).lastPurchasePriceHt,
    ).toBe(130000);
  });

  it('id d’une réception EXISTANTE réutilisé : REJETEE définitivement (la file ne gèle pas)', async () => {
    const order = await confirmedOrder('10');
    const first = body(order, '1');
    await sync(tokens.magasinier, [mutation(first)]);

    const res = await sync(tokens.magasinier, [
      mutation(body(order, '1', { id: first.id })),
    ]);

    expect(res.body.results[0]).toMatchObject({
      status: 'REJETEE',
      code: 'CONFLICT',
    });
  });

  it('clé d’une réception d’un AUTRE compte : REJETEE sans en révéler le contenu', async () => {
    const order = await confirmedOrder('10');
    const b = body(order, '1');
    await sync(tokens.magasinier, [mutation(b)]);

    const res = await sync(tokens.admin, [mutation(b)]);

    expect(res.body.results[0].status).toBe('REJETEE');
    expect(JSON.stringify(res.body)).not.toMatch(/BR-\d{4}/);
    expect(await stockOf(order.productId)).toBe('1.000');
  });

  it('même réception EN LIGNE et par /sync en même temps : jamais de faux rejet, une seule entrée', async () => {
    const order = await confirmedOrder('10');
    // La totalité : si la seconde passait, ce serait une « surlivraison ».
    const b = body(order, '10');
    const [online, synced] = await Promise.all([
      as(tokens.magasinier).post('/api/receptions').send(b),
      sync(tokens.magasinier, [mutation(b)]),
    ]);

    expect([201, 409]).toContain(online.status);
    expect(['CONFIRMEE', 'NON_TRAITEE']).toContain(
      synced.body.results[0].status,
    );
    const again = await sync(tokens.magasinier, [mutation(b)]);
    expect(again.body.results[0].status).toBe('CONFIRMEE');
    expect(await receptionsWithKey(b.clientMutationId)).toBe(1);
    expect(await stockOf(order.productId)).toBe('10.000');
  });
});
