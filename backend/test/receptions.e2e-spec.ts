import { randomUUID } from 'crypto';
import * as request from 'supertest';
import { RoleCode } from '../src/common/auth.decorators';
import { PrismaService } from '../src/prisma/prisma.service';
import { createE2eApp, createTestUser, E2eApp } from './helpers/e2e-app';

/// Réceptions (P0 n°7). Décisions MEDMEDBEN 2026-09-16 : la dette fournisseur
/// naît à la RÉCEPTION (quantités réellement reçues) et la SURLIVRAISON est
/// refusée. Le stock n'augmente que du reçu (règle 6).
describe('Réceptions (e2e)', () => {
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
    get: (url: string) =>
      request(server).get(url).set('Authorization', `Bearer ${token}`),
    post: (url: string) =>
      request(server).post(url).set('Authorization', `Bearer ${token}`),
  });

  /// Produit taxé à 19 % — le taux figé sur la ligne de COMMANDE est celui qui
  /// doit servir au TTC de la réception.
  const product = async () => {
    const n = ++counter;
    const tva = await prisma.taxRate.findFirstOrThrow({ where: { rate: 19 } });
    const created = await prisma.product.create({
      data: {
        sku: `E2E-BR-${suffix}-${n}`,
        barcode: `E2E-BR-BR-${suffix}-${n}`,
        name: `Produit réception ${n}`,
        taxRateId: tva.id,
      },
    });
    productIds.push(created.id);
    return created.id;
  };

  /// Commande CONFIRMÉE de `quantity` unités à 1 200,00 HT, prête à recevoir.
  const confirmedOrder = async (quantity = '100') => {
    const productId = await product();
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

  const debt = async () =>
    (await as(tokens.admin).get(`/api/suppliers/${supplierId}`).expect(200))
      .body.balanceDue as number;

  const stockOf = async (productId: string) =>
    (
      await prisma.stock.findFirst({
        where: { productId, locationId: depotId },
      })
    )?.quantity.toFixed(3) ?? '0.000';

  beforeAll(async () => {
    e2e = await createE2eApp();
    prisma = e2e.prisma;
    server = e2e.server;
    for (const [key, role] of [
      ['admin', RoleCode.ADMIN],
      ['magasinier', RoleCode.MAGASINIER],
      ['vendeur', RoleCode.VENDEUR],
    ] as const) {
      const email = `e2e-reception-${key}-${suffix}@test.local`;
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
      data: { name: `Fournisseur réceptions ${suffix}` },
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

  it('réception partielle : stock +reçu, commande PARTIELLEMENT_RECUE, dette +TTC reçu', async () => {
    const order = await confirmedOrder('100');
    const before = await debt();

    const reception = (
      await as(tokens.magasinier)
        .post('/api/receptions')
        .send({
          purchaseOrderId: order.id,
          supplierId,
          locationId: depotId,
          lines: [
            {
              productId: order.productId,
              purchaseLineId: order.lineId,
              receivedQuantity: '70',
              unitPriceHt: 120000,
            },
          ],
        })
        .expect(201)
    ).body;

    expect(reception.number).toMatch(/^BR-\d{4}-\d{5}$/);
    // 70 × 1 200,00 = 84 000,00 HT ; TVA 19 % = 15 960,00 ; TTC = 99 960,00
    expect(reception.lines[0].lineTotalHt).toBe(8400000);
    expect(reception.totalTtc).toBe(9996000);

    expect(await stockOf(order.productId)).toBe('70.000');
    expect(await debt()).toBe(before + 9996000);

    const detail = (
      await as(tokens.magasinier)
        .get(`/api/purchase-orders/${order.id}`)
        .expect(200)
    ).body;
    expect(detail.status).toBe('PARTIELLEMENT_RECUE');
    expect(detail.lines[0]).toMatchObject({
      receivedQuantity: '70.000',
      remainingQuantity: '30.000',
    });

    // Règle 5 : le coût du produit suit le dernier prix réceptionné.
    const updated = await prisma.product.findUniqueOrThrow({
      where: { id: order.productId },
    });
    expect(updated.lastPurchasePriceHt).toBe(120000);
  });

  it('le solde de la commande la passe RECUE et ne la reçoit plus ensuite', async () => {
    const order = await confirmedOrder('10');
    const line = (quantity: string) => ({
      purchaseOrderId: order.id,
      supplierId,
      locationId: depotId,
      lines: [
        {
          productId: order.productId,
          purchaseLineId: order.lineId,
          receivedQuantity: quantity,
          unitPriceHt: 100000,
        },
      ],
    });

    await as(tokens.magasinier)
      .post('/api/receptions')
      .send(line('4'))
      .expect(201);
    await as(tokens.magasinier)
      .post('/api/receptions')
      .send(line('6'))
      .expect(201);

    const detail = (
      await as(tokens.admin).get(`/api/purchase-orders/${order.id}`).expect(200)
    ).body;
    expect(detail.status).toBe('RECUE');
    expect(detail.lines[0].remainingQuantity).toBe('0.000');
    expect(await stockOf(order.productId)).toBe('10.000');

    // Commande soldée : plus rien n'entre dessus.
    const refused = await as(tokens.magasinier)
      .post('/api/receptions')
      .send(line('1'))
      .expect(409);
    expect(refused.body.code).toBe('INVALID_STATE_TRANSITION');
  });

  it('surlivraison refusée, y compris en cumulant deux lignes du même bon', async () => {
    const order = await confirmedOrder('10');

    const tooMuch = await as(tokens.magasinier)
      .post('/api/receptions')
      .send({
        purchaseOrderId: order.id,
        supplierId,
        locationId: depotId,
        lines: [
          {
            productId: order.productId,
            purchaseLineId: order.lineId,
            receivedQuantity: '11',
            unitPriceHt: 120000,
          },
        ],
      })
      .expect(422);
    expect(tooMuch.body.code).toBe('VALIDATION_FAILED');
    expect(tooMuch.body.message).toContain('Surlivraison');

    // 6 + 6 sur une commande de 10 : refusé AVANT toute écriture.
    await as(tokens.magasinier)
      .post('/api/receptions')
      .send({
        purchaseOrderId: order.id,
        supplierId,
        locationId: depotId,
        lines: [6, 6].map(() => ({
          productId: order.productId,
          purchaseLineId: order.lineId,
          receivedQuantity: '6',
          unitPriceHt: 120000,
        })),
      })
      .expect(422);

    expect(await stockOf(order.productId)).toBe('0.000');
    const detail = (
      await as(tokens.admin).get(`/api/purchase-orders/${order.id}`).expect(200)
    ).body;
    expect(detail.status).toBe('CONFIRMEE');
  });

  it('commande annulée ou non confirmée : aucune réception', async () => {
    const cancelled = await confirmedOrder('5');
    // Une commande confirmée sans réception peut encore être annulée.
    await as(tokens.admin)
      .post(`/api/purchase-orders/${cancelled.id}/cancel`)
      .expect(200);
    const refused = await as(tokens.magasinier)
      .post('/api/receptions')
      .send({
        purchaseOrderId: cancelled.id,
        supplierId,
        locationId: depotId,
        lines: [
          {
            productId: cancelled.productId,
            purchaseLineId: cancelled.lineId,
            receivedQuantity: '1',
            unitPriceHt: 120000,
          },
        ],
      })
      .expect(409);
    expect(refused.body.code).toBe('INVALID_STATE_TRANSITION');

    const productId = await product();
    const draft = (
      await as(tokens.magasinier)
        .post('/api/purchase-orders')
        .send({
          supplierId,
          lines: [{ productId, orderedQuantity: '5', unitPriceHt: 120000 }],
        })
        .expect(201)
    ).body;
    orderIds.push(draft.id);
    await as(tokens.magasinier)
      .post('/api/receptions')
      .send({
        purchaseOrderId: draft.id,
        supplierId,
        locationId: depotId,
        lines: [
          {
            productId,
            purchaseLineId: draft.lines[0].id,
            receivedQuantity: '1',
            unitPriceHt: 120000,
          },
        ],
      })
      .expect(409);
    expect(await stockOf(productId)).toBe('0.000');
  });

  it('annulation et réception simultanées : une seule des deux passe', async () => {
    // Répété : une course ne se rejoue pas à l'identique, mais SANS le verrou
    // partagé l'une des passes laisse commande annulée ET stock entré.
    for (let attempt = 0; attempt < 6; attempt++)
      await raceCancelAndReception();
  });

  const raceCancelAndReception = async () => {
    const order = await confirmedOrder('5');
    const [cancel, reception] = await Promise.allSettled([
      as(tokens.admin).post(`/api/purchase-orders/${order.id}/cancel`).send({}),
      as(tokens.magasinier)
        .post('/api/receptions')
        .send({
          purchaseOrderId: order.id,
          supplierId,
          locationId: depotId,
          lines: [
            {
              productId: order.productId,
              purchaseLineId: order.lineId,
              receivedQuantity: '5',
              unitPriceHt: 120000,
            },
          ],
        }),
    ]);
    const status = (r: PromiseSettledResult<{ status: number }>) =>
      r.status === 'fulfilled' ? r.value.status : 500;
    const ok = [status(cancel) === 200, status(reception) === 201];
    expect(ok.filter(Boolean)).toHaveLength(1);

    const detail = (
      await as(tokens.admin).get(`/api/purchase-orders/${order.id}`).expect(200)
    ).body;
    // L'état final est cohérent avec celle qui a gagné : annulée SANS stock,
    // ou reçue AVEC le stock — jamais les deux.
    if (detail.status === 'ANNULEE') {
      expect(await stockOf(order.productId)).toBe('0.000');
    } else {
      expect(detail.status).toBe('RECUE');
      expect(await stockOf(order.productId)).toBe('5.000');
    }
  };

  it('renvoi de la même clé : même bon, marchandise entrée une seule fois', async () => {
    const order = await confirmedOrder('8');
    const body = {
      clientMutationId: randomUUID(),
      purchaseOrderId: order.id,
      supplierId,
      locationId: depotId,
      lines: [
        {
          productId: order.productId,
          purchaseLineId: order.lineId,
          receivedQuantity: '8',
          unitPriceHt: 120000,
        },
      ],
    };
    const first = await as(tokens.magasinier)
      .post('/api/receptions')
      .send(body)
      .expect(201);
    const debtAfterFirst = await debt();

    const replay = await as(tokens.magasinier)
      .post('/api/receptions')
      .send(body)
      .expect(201);
    expect(replay.body.id).toBe(first.body.id);
    expect(await stockOf(order.productId)).toBe('8.000');
    expect(await debt()).toBe(debtAfterFirst);

    // Même clé, AUTRE contenu : la première réception existe déjà.
    const conflict = await as(tokens.magasinier)
      .post('/api/receptions')
      .send({
        ...body,
        lines: [{ ...body.lines[0], receivedQuantity: '1' }],
      })
      .expect(409);
    expect(conflict.body.code).toBe('CONFLICT');
  });

  it('réception hors commande : ADMIN seul, elle endette quand même le fournisseur', async () => {
    const productId = await product();
    const before = await debt();

    // Hors commande, la réception EST un achat : le magasinier ne la fait pas.
    const refused = await as(tokens.magasinier)
      .post('/api/receptions')
      .send({
        supplierId,
        locationId: depotId,
        lines: [{ productId, receivedQuantity: '3', unitPriceHt: 100000 }],
      })
      .expect(403);
    expect(refused.body.code).toBe('FORBIDDEN_ROLE');
    expect(await stockOf(productId)).toBe('0.000');

    const reception = (
      await as(tokens.admin)
        .post('/api/receptions')
        .send({
          supplierId,
          locationId: depotId,
          lines: [{ productId, receivedQuantity: '3', unitPriceHt: 100000 }],
        })
        .expect(201)
    ).body;

    // 3 × 1 000,00 = 3 000,00 HT ; TVA 19 % = 570,00 ; TTC = 3 570,00
    expect(reception.totalTtc).toBe(357000);
    expect(reception.purchaseOrderId).toBeNull();
    expect(await stockOf(productId)).toBe('3.000');
    expect(await debt()).toBe(before + 357000);
  });

  it('ligne rattachée à une AUTRE commande : refusée', async () => {
    const a = await confirmedOrder('5');
    const b = await confirmedOrder('5');
    const refused = await as(tokens.magasinier)
      .post('/api/receptions')
      .send({
        purchaseOrderId: a.id,
        supplierId,
        locationId: depotId,
        lines: [
          {
            productId: b.productId,
            purchaseLineId: b.lineId,
            receivedQuantity: '1',
            unitPriceHt: 120000,
          },
        ],
      })
      .expect(422);
    expect(refused.body.message).toContain('absente de cette commande');
  });

  it('liste filtrée par commande ; le vendeur n’a aucun accès', async () => {
    const order = await confirmedOrder('2');
    await as(tokens.magasinier)
      .post('/api/receptions')
      .send({
        purchaseOrderId: order.id,
        supplierId,
        locationId: depotId,
        lines: [
          {
            productId: order.productId,
            purchaseLineId: order.lineId,
            receivedQuantity: '2',
            unitPriceHt: 120000,
          },
        ],
      })
      .expect(201);

    const list = await as(tokens.admin)
      .get(`/api/receptions?purchaseOrderId=${order.id}`)
      .expect(200);
    expect(list.body.data).toHaveLength(1);
    expect(list.body.data[0].purchaseOrderId).toBe(order.id);

    await as(tokens.vendeur).get('/api/receptions').expect(403);
  });

  it('le prix vient de la COMMANDE confirmée, pas du magasinier', async () => {
    const order = await confirmedOrder('10');
    const before = await debt();

    // Le bon annonce 1 centime l'unité ; la commande confirmée dit 1 200,00 HT.
    const reception = (
      await as(tokens.magasinier)
        .post('/api/receptions')
        .send({
          purchaseOrderId: order.id,
          supplierId,
          locationId: depotId,
          lines: [
            {
              productId: order.productId,
              purchaseLineId: order.lineId,
              receivedQuantity: '10',
              unitPriceHt: 1,
            },
          ],
        })
        .expect(201)
    ).body;

    // 10 × 1 200,00 = 12 000,00 HT ; TVA 19 % = 2 280,00 ; TTC = 14 280,00
    expect(reception.lines[0].unitPriceHt).toBe(120000);
    expect(reception.totalTtc).toBe(1428000);
    expect(await debt()).toBe(before + 1428000);

    const updated = await prisma.product.findUniqueOrThrow({
      where: { id: order.productId },
    });
    expect(updated.lastPurchasePriceHt).toBe(120000);
  });

  it('quantité mal formée : refusée par le contrat, rien n’entre', async () => {
    const order = await confirmedOrder('5');
    await as(tokens.magasinier)
      .post('/api/receptions')
      .send({
        purchaseOrderId: order.id,
        supplierId,
        locationId: depotId,
        lines: [
          {
            productId: order.productId,
            purchaseLineId: order.lineId,
            receivedQuantity: '1,5',
            unitPriceHt: 120000,
          },
        ],
      })
      .expect(400);
    expect(await stockOf(order.productId)).toBe('0.000');
  });
});
