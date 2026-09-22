import { randomUUID } from 'crypto';
import * as request from 'supertest';
import { RoleCode } from '../src/common/auth.decorators';
import { PrismaService } from '../src/prisma/prisma.service';
import { createE2eApp, createTestUser, E2eApp } from './helpers/e2e-app';
import { authorOf } from './helpers/sync-author';

/// Transferts hors-ligne (P0 #12 tranche E) : chaque étape passe par le MÊME
/// cœur que sa route, avec ses droits propres ; une étape déjà faite en ligne
/// (réponse perdue) est reconnue par l'état atteint.
describe('Transferts hors-ligne par /sync (e2e)', () => {
  let e2e: E2eApp;
  let prisma: PrismaService;
  let server: E2eApp['server'];

  const suffix = Date.now();
  const PASSWORD = 'MotDePasseTemp1!';
  const userIds: string[] = [];
  const productIds: string[] = [];
  const tokens: Record<string, string> = {};
  let depotId = '';
  let magasinId = '';
  let counter = 0;

  const as = (token: string) => ({
    post: (url: string) =>
      request(server).post(url).set('Authorization', `Bearer ${token}`),
  });

  const productWithStock = async (quantity = '100') => {
    const n = ++counter;
    const created = (
      await as(tokens.admin)
        .post('/api/products')
        .send({
          sku: `E2E-SYNCTRF-${suffix}-${n}`,
          name: `Produit transfert hors-ligne ${n}`,
          unit: 'PIECE',
          initialStock: [{ locationId: depotId, quantity }],
        })
        .expect(201)
    ).body;
    productIds.push(created.id);
    return created.id as string;
  };

  let clock = Date.now() - 3600_000;
  const mutation = (payload: Record<string, unknown>) => ({
    clientMutationId: payload.clientMutationId,
    deviceId: 'e2e-poste',
    operationType: 'TRANSFER',
    deviceTimestamp: new Date((clock += 1000)).toISOString(),
    payload,
  });

  const step = (
    action: string,
    transferId: string,
    body: Record<string, unknown> = {},
  ) => ({ action, clientMutationId: randomUUID(), transferId, ...body });

  const sync = (token: string, mutations: unknown[]) =>
    request(server)
      .post('/api/sync')
      .set('Authorization', `Bearer ${token}`)
      .send({ authorUserId: authorOf(token), mutations })
      .expect(200);

  const stockAt = async (productId: string, locationId: string) =>
    (
      await prisma.stock.findFirst({ where: { productId, locationId } })
    )?.quantity.toFixed(3) ?? '0.000';

  const statusOf = async (id: string) =>
    (await prisma.transfer.findUniqueOrThrow({ where: { id } })).status;

  beforeAll(async () => {
    e2e = await createE2eApp();
    prisma = e2e.prisma;
    server = e2e.server;
    for (const [key, role] of [
      ['admin', RoleCode.ADMIN],
      ['magasinier', RoleCode.MAGASINIER],
      ['vendeur', RoleCode.VENDEUR],
      ['vendeur2', RoleCode.VENDEUR],
      ['magasinier2', RoleCode.MAGASINIER],
    ] as const) {
      const email = `e2e-synctrf-${key}-${suffix}@test.local`;
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
    depotId = (
      await prisma.location.findFirstOrThrow({ where: { type: 'DEPOT' } })
    ).id;
    magasinId = (
      await prisma.location.findFirstOrThrow({ where: { type: 'MAGASIN' } })
    ).id;
  });

  afterAll(async () => {
    const transfers = await prisma.transfer.findMany({
      where: { requestedById: { in: userIds } },
      select: { id: true },
    });
    const transferIds = transfers.map((t) => t.id);
    await prisma.auditLog.deleteMany({ where: { userId: { in: userIds } } });
    await prisma.syncMutation.deleteMany({
      where: { userId: { in: userIds } },
    });
    await prisma.transferLine.deleteMany({
      where: { transferId: { in: transferIds } },
    });
    await prisma.transfer.deleteMany({ where: { id: { in: transferIds } } });
    await prisma.stockMovement.deleteMany({
      where: { productId: { in: productIds } },
    });
    await prisma.stock.deleteMany({ where: { productId: { in: productIds } } });
    await prisma.product.deleteMany({ where: { id: { in: productIds } } });
    await prisma.user.deleteMany({ where: { id: { in: userIds } } });
    await e2e.app.close();
  });

  it('flux complet hors-ligne : demande (magasin) → préparation + expédition (dépôt) → réception (magasin)', async () => {
    const productId = await productWithStock('100');
    const request_ = {
      action: 'REQUEST',
      clientMutationId: randomUUID(),
      id: randomUUID(),
      lines: [{ productId, quantity: '20' }],
    };
    const asked = await sync(tokens.vendeur, [mutation(request_)]);
    expect(asked.body.results[0]).toMatchObject({
      status: 'CONFIRMEE',
      entityId: request_.id,
    });

    const depot = await sync(tokens.magasinier, [
      mutation(step('ACCEPT', request_.id)),
      mutation(
        step('PREPARE', request_.id, {
          lines: [{ productId, preparedQuantity: '18' }],
        }),
      ),
      mutation(step('SHIP', request_.id)),
    ]);
    expect(depot.body.results.map((r: { status: string }) => r.status)).toEqual(
      ['CONFIRMEE', 'CONFIRMEE', 'CONFIRMEE'],
    );
    expect(await stockAt(productId, depotId)).toBe('82.000');

    const store = await sync(tokens.vendeur, [
      mutation(
        step('RECEIVE', request_.id, {
          lines: [{ productId, receivedQuantity: '17' }],
        }),
      ),
    ]);
    expect(store.body.results[0].status).toBe('CONFIRMEE');
    expect(await statusOf(request_.id)).toBe('RECUE');
    expect(await stockAt(productId, magasinId)).toBe('17.000');
    // L'écart (1) retourne au dépôt, comme en ligne.
    expect(await stockAt(productId, depotId)).toBe('83.000');
  });

  it('expédition faite EN LIGNE (réponse perdue) puis par la file : reconnue, stock sorti UNE fois', async () => {
    const productId = await productWithStock('100');
    const created = (
      await as(tokens.vendeur)
        .post('/api/transfers')
        .send({
          clientMutationId: randomUUID(),
          lines: [{ productId, quantity: '10' }],
        })
        .expect(201)
    ).body;
    await as(tokens.magasinier)
      .post(`/api/transfers/${created.id}/prepare`)
      .send({ lines: [{ productId, preparedQuantity: '10' }] })
      .expect(200);
    await as(tokens.magasinier)
      .post(`/api/transfers/${created.id}/ship`)
      .expect(200);

    const res = await sync(tokens.magasinier, [
      mutation(step('SHIP', created.id)),
    ]);

    expect(res.body.results[0].status).toBe('CONFIRMEE');
    expect(await stockAt(productId, depotId)).toBe('90.000');
  });

  it('demande faite EN LIGNE puis même clé par la file : reconnue, une seule demande', async () => {
    const productId = await productWithStock('100');
    const body = {
      clientMutationId: randomUUID(),
      id: randomUUID(),
      lines: [{ productId, quantity: '5' }],
    };
    await as(tokens.vendeur).post('/api/transfers').send(body).expect(201);

    const res = await sync(tokens.vendeur, [
      mutation({ action: 'REQUEST', ...body }),
    ]);

    expect(res.body.results[0]).toMatchObject({
      status: 'CONFIRMEE',
      entityId: body.id,
    });
    expect(
      await prisma.transfer.count({
        where: { clientMutationId: body.clientMutationId },
      }),
    ).toBe(1);
  });

  it('droits PAR ÉTAPE : un vendeur n’expédie pas, un magasinier ne demande pas', async () => {
    const productId = await productWithStock('100');
    const request_ = {
      action: 'REQUEST',
      clientMutationId: randomUUID(),
      id: randomUUID(),
      lines: [{ productId, quantity: '5' }],
    };
    const byMagasinier = await sync(tokens.magasinier, [mutation(request_)]);
    expect(byMagasinier.body.results[0]).toMatchObject({
      status: 'REJETEE',
      code: 'FORBIDDEN_ROLE',
    });

    await sync(tokens.vendeur, [
      mutation({ ...request_, clientMutationId: randomUUID() }),
    ]);
    const shipByVendeur = await sync(tokens.vendeur, [
      mutation(step('SHIP', request_.id)),
    ]);
    expect(shipByVendeur.body.results[0]).toMatchObject({
      status: 'REJETEE',
      code: 'FORBIDDEN_ROLE',
    });
    expect(await stockAt(productId, depotId)).toBe('100.000');
  });

  it('expédition hors-ligne d’un transfert ANNULÉ entre-temps : REJETEE, rien ne bouge', async () => {
    const productId = await productWithStock('100');
    const created = (
      await as(tokens.vendeur)
        .post('/api/transfers')
        .send({
          clientMutationId: randomUUID(),
          lines: [{ productId, quantity: '5' }],
        })
        .expect(201)
    ).body;
    await as(tokens.vendeur)
      .post(`/api/transfers/${created.id}/cancel`)
      .send({ status: 'ANNULEE' })
      .expect(200);

    const res = await sync(tokens.magasinier, [
      mutation(step('SHIP', created.id)),
    ]);

    expect(res.body.results[0]).toMatchObject({
      status: 'REJETEE',
      code: 'INVALID_STATE_TRANSITION',
    });
    expect(await stockAt(productId, depotId)).toBe('100.000');
  });

  it('étape inconnue ou champ en trop : REJETEE', async () => {
    const productId = await productWithStock('100');
    for (const payload of [
      step('TELEPORT', randomUUID()),
      step('SHIP', randomUUID(), { quantity: '999' }),
    ]) {
      const res = await sync(tokens.magasinier, [mutation(payload)]);
      expect(res.body.results[0]).toMatchObject({
        status: 'REJETEE',
        code: 'VALIDATION_FAILED',
      });
    }
    expect(await stockAt(productId, depotId)).toBe('100.000');
  });

  const onlineRequest = async (productId: string, token = tokens.vendeur) =>
    (
      await as(token)
        .post('/api/transfers')
        .send({
          clientMutationId: randomUUID(),
          lines: [{ productId, quantity: '5' }],
        })
        .expect(201)
    ).body.id as string;

  it('annulation hors-ligne de la demande d’un AUTRE vendeur, même déjà annulée : refusée, jamais attribuée', async () => {
    const productId = await productWithStock('100');
    const id = await onlineRequest(productId);
    await as(tokens.vendeur)
      .post(`/api/transfers/${id}/cancel`)
      .send({ status: 'ANNULEE' })
      .expect(200);

    const res = await sync(tokens.vendeur2, [
      mutation(step('CLOSE', id, { status: 'ANNULEE' })),
    ]);

    expect(res.body.results[0]).toMatchObject({
      status: 'REJETEE',
      code: 'FORBIDDEN_ROLE',
    });
  });

  it('refus hors-ligne par un VENDEUR, même sur un transfert déjà refusé : refusé', async () => {
    const productId = await productWithStock('100');
    const id = await onlineRequest(productId);
    await as(tokens.magasinier)
      .post(`/api/transfers/${id}/cancel`)
      .send({ status: 'REFUSEE' })
      .expect(200);

    const res = await sync(tokens.vendeur, [
      mutation(step('CLOSE', id, { status: 'REFUSEE' })),
    ]);

    expect(res.body.results[0]).toMatchObject({
      status: 'REJETEE',
      code: 'FORBIDDEN_ROLE',
    });
  });

  it('étape déjà faite par un AUTRE magasinier : REJETEE (jamais « confirmée » à son nom)', async () => {
    const productId = await productWithStock('100');
    const id = await onlineRequest(productId);
    await as(tokens.magasinier)
      .post(`/api/transfers/${id}/prepare`)
      .send({ lines: [{ productId, preparedQuantity: '5' }] })
      .expect(200);
    await as(tokens.magasinier).post(`/api/transfers/${id}/ship`).expect(200);

    const res = await sync(tokens.magasinier2, [mutation(step('SHIP', id))]);

    expect(res.body.results[0]).toMatchObject({
      status: 'REJETEE',
      code: 'INVALID_STATE_TRANSITION',
    });
    expect(await stockAt(productId, depotId)).toBe('95.000');
  });

  it('CORRECTION de préparation hors-ligne par le même magasinier : réappliquée, jamais jetée', async () => {
    const productId = await productWithStock('100');
    const id = await onlineRequest(productId);
    await as(tokens.magasinier)
      .post(`/api/transfers/${id}/prepare`)
      .send({ lines: [{ productId, preparedQuantity: '5' }] })
      .expect(200);

    const res = await sync(tokens.magasinier, [
      mutation(
        step('PREPARE', id, { lines: [{ productId, preparedQuantity: '3' }] }),
      ),
    ]);

    expect(res.body.results[0].status).toBe('CONFIRMEE');
    const line = await prisma.transferLine.findFirstOrThrow({
      where: { transferId: id },
    });
    expect(line.preparedQuantity.toFixed(3)).toBe('3.000');
  });

  it('clôture déjà faite, même par soi : REJETEE (jamais « reconnue » sans savoir qui l’a faite)', async () => {
    const productId = await productWithStock('100');
    const id = await onlineRequest(productId);
    await as(tokens.vendeur)
      .post(`/api/transfers/${id}/cancel`)
      .send({ status: 'ANNULEE' })
      .expect(200);

    const res = await sync(tokens.vendeur, [
      mutation(step('CLOSE', id, { status: 'ANNULEE' })),
    ]);

    expect(res.body.results[0]).toMatchObject({
      status: 'REJETEE',
      code: 'INVALID_STATE_TRANSITION',
    });
  });

  it('même demande EN LIGNE et par /sync en même temps : jamais de doublon ni de faux rejet', async () => {
    const productId = await productWithStock('100');
    const body = {
      clientMutationId: randomUUID(),
      id: randomUUID(),
      lines: [{ productId, quantity: '5' }],
    };
    const [online, synced] = await Promise.all([
      as(tokens.vendeur).post('/api/transfers').send(body),
      sync(tokens.vendeur, [mutation({ action: 'REQUEST', ...body })]),
    ]);

    expect([201, 409]).toContain(online.status);
    expect(['CONFIRMEE', 'NON_TRAITEE']).toContain(
      synced.body.results[0].status,
    );
    const again = await sync(tokens.vendeur, [
      mutation({ action: 'REQUEST', ...body }),
    ]);
    expect(again.body.results[0].status).toBe('CONFIRMEE');
    expect(
      await prisma.transfer.count({
        where: { clientMutationId: body.clientMutationId },
      }),
    ).toBe(1);
  });
});
