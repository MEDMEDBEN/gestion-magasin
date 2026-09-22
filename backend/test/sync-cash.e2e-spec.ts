import { randomUUID } from 'crypto';
import * as request from 'supertest';
import { RoleCode } from '../src/common/auth.decorators';
import { PrismaService } from '../src/prisma/prisma.service';
import { createE2eApp, createTestUser, E2eApp } from './helpers/e2e-app';
import { authorOf } from './helpers/sync-author';

/// Caisse hors-ligne (P0 #12 tranche C) : ouverture et clôture par la file, avec
/// le MÊME cœur que les routes en ligne, et reconnaissance d'une opération
/// déjà faite en ligne sous la même clé.
describe('Caisse hors-ligne par /sync (e2e)', () => {
  let e2e: E2eApp;
  let prisma: PrismaService;
  let server: E2eApp['server'];

  const suffix = Date.now();
  const PASSWORD = 'MotDePasseTemp1!';
  const userIds: string[] = [];
  const productIds: string[] = [];
  let magasinId = '';
  let detailId = '';
  let tva19Id = '';
  let counter = 0;
  /// 1 450,00 HT, TVA 19 % : une unité = 1 725,50 TTC.
  const UNIT_TTC = 172550;

  /// Un compte neuf par test : une seule caisse ouverte par compte.
  const account = async (role: RoleCode): Promise<string> => {
    const email = `e2e-synccash-${++counter}-${suffix}@test.local`;
    const user = await createTestUser(prisma, {
      email,
      password: PASSWORD,
      roles: [role],
    });
    userIds.push(user.id);
    return (
      await request(server)
        .post('/api/auth/login')
        .send({ identifier: email, password: PASSWORD })
        .expect(200)
    ).body.accessToken;
  };

  const product = async (stock: string) => {
    const n = ++counter;
    const created = await prisma.product.create({
      data: {
        sku: `E2E-SYNCCASH-${suffix}-${n}`,
        barcode: `E2E-SYNCCASH-BC-${suffix}-${n}`,
        name: `Produit caisse hors-ligne ${n}`,
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

  /// Horodatages croissants : l'ordre de saisie sur l'appareil.
  let clock = Date.now() - 3600_000;
  const mutation = (
    operationType: string,
    payload: Record<string, unknown>,
  ) => ({
    clientMutationId: payload.clientMutationId,
    deviceId: 'e2e-caisse',
    operationType,
    deviceTimestamp: new Date((clock += 1000)).toISOString(),
    payload,
  });

  const openBody = (over: Record<string, unknown> = {}) => ({
    action: 'OPEN',
    clientMutationId: randomUUID(),
    id: randomUUID(),
    locationId: magasinId,
    openingFloat: 500000,
    ...over,
  });

  const closeBody = (sessionId: string, countedAmount: number) => ({
    action: 'CLOSE',
    clientMutationId: randomUUID(),
    sessionId,
    countedAmount,
  });

  const sync = (token: string, mutations: unknown[]) =>
    request(server)
      .post('/api/sync')
      .set('Authorization', `Bearer ${token}`)
      .send({ authorUserId: authorOf(token), mutations })
      .expect(200);

  /// Corps de route en ligne : sans `action` (réservé à la file).
  const online = ({ action: _a, ...body }: Record<string, unknown>) => body;

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
  });

  afterAll(async () => {
    const sales = await prisma.sale.findMany({
      where: { userId: { in: userIds } },
      select: { id: true },
    });
    const saleIds = sales.map((s) => s.id);
    await prisma.auditLog.deleteMany({ where: { userId: { in: userIds } } });
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
    await prisma.user.deleteMany({ where: { id: { in: userIds } } });
    await e2e.app.close();
  });

  it('journée entière hors-ligne : ouverture → vente → clôture, rapport Z juste', async () => {
    const token = await account(RoleCode.VENDEUR);
    const p = await product('5.000');
    const open = openBody();
    const sale = {
      clientMutationId: randomUUID(),
      id: randomUUID(),
      cashSessionId: open.id,
      lines: [{ productId: p, quantity: '1.000' }],
      paidAmount: UNIT_TTC,
      expectedTotalTtc: UNIT_TTC,
    };
    const close = closeBody(open.id, 500000 + UNIT_TTC);

    const batch = [
      mutation('CASH_SESSION', open),
      mutation('SALE', sale),
      mutation('CASH_SESSION', close),
    ];
    const res = await sync(token, batch);

    expect(res.body.results.map((r: { status: string }) => r.status)).toEqual([
      'CONFIRMEE',
      'CONFIRMEE',
      'CONFIRMEE',
    ]);
    const session = await prisma.cashSession.findUniqueOrThrow({
      where: { id: open.id },
    });
    expect(session).toMatchObject({
      status: 'CLOTUREE',
      openingFloat: 500000,
      expectedAmount: 500000 + UNIT_TTC,
      countedAmount: 500000 + UNIT_TTC,
      difference: 0,
    });
    // Datée de l'APPAREIL : ses ventes hors-ligne ne la précèdent pas.
    expect(session.openedAt.toISOString()).toBe(batch[0].deviceTimestamp);
    expect(session.closedAt?.toISOString()).toBe(batch[2].deviceTimestamp);
    const audits = await prisma.auditLog.findMany({
      where: { entityId: open.id },
      select: { action: true },
    });
    expect(audits.map((a) => a.action).sort()).toEqual(['CREATE', 'VALIDATE']);
  });

  it('ouverture faite EN LIGNE (réponse perdue) puis même clé par la file : reconnue', async () => {
    const token = await account(RoleCode.VENDEUR);
    const open = openBody();
    await request(server)
      .post('/api/cash-sessions')
      .set('Authorization', `Bearer ${token}`)
      .send(online(open))
      .expect(201);

    const res = await sync(token, [mutation('CASH_SESSION', open)]);

    expect(res.body.results[0]).toMatchObject({
      status: 'CONFIRMEE',
      entityId: open.id,
    });
    expect(
      await prisma.cashSession.count({ where: { userId: authorOf(token) } }),
    ).toBe(1);
    // Le journal ne prétend pas qu'elle a été faite hors ligne.
    const traced = await prisma.auditLog.findMany({
      where: { entityId: open.id },
      select: { newValue: true },
    });
    expect(traced.map((t) => t.newValue)).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ alreadyRecordedOnline: true }),
      ]),
    );
    expect(JSON.stringify(traced)).not.toContain('"offline":true');
  });

  it('clôture faite EN LIGNE puis même clé par la file : même rapport, pas de seconde clôture', async () => {
    const token = await account(RoleCode.VENDEUR);
    const open = openBody();
    await sync(token, [mutation('CASH_SESSION', open)]);
    const close = closeBody(open.id, 490000);
    await request(server)
      .post(`/api/cash-sessions/${open.id}/close`)
      .set('Authorization', `Bearer ${token}`)
      .send(online({ ...close, sessionId: undefined }))
      .expect(200);

    const res = await sync(token, [mutation('CASH_SESSION', close)]);

    expect(res.body.results[0]).toMatchObject({
      status: 'CONFIRMEE',
      serverState: { status: 'CLOTUREE', difference: '-10000' },
    });
  });

  it('ouverture hors-ligne alors qu’une caisse est déjà ouverte : REJETEE', async () => {
    const token = await account(RoleCode.VENDEUR);
    await sync(token, [mutation('CASH_SESSION', openBody())]);
    const res = await sync(token, [mutation('CASH_SESSION', openBody())]);

    expect(res.body.results[0]).toMatchObject({
      status: 'REJETEE',
      code: 'CASH_SESSION_ALREADY_OPEN',
    });
  });

  it('clôture de la caisse d’un AUTRE vendeur : REJETEE comme introuvable', async () => {
    const owner = await account(RoleCode.VENDEUR);
    const other = await account(RoleCode.VENDEUR);
    const open = openBody();
    await sync(owner, [mutation('CASH_SESSION', open)]);

    const res = await sync(other, [
      mutation('CASH_SESSION', closeBody(open.id, 0)),
    ]);

    expect(res.body.results[0]).toMatchObject({
      status: 'REJETEE',
      code: 'NOT_FOUND',
    });
    expect(
      (await prisma.cashSession.findUniqueOrThrow({ where: { id: open.id } }))
        .status,
    ).toBe('OUVERTE');
  });

  it('MAGASINIER : refusé comme en ligne', async () => {
    const token = await account(RoleCode.MAGASINIER);
    const res = await sync(token, [mutation('CASH_SESSION', openBody())]);
    expect(res.body.results[0]).toMatchObject({
      status: 'REJETEE',
      code: 'FORBIDDEN_ROLE',
    });
  });

  it('action inconnue ou champ en trop : REJETEE', async () => {
    const token = await account(RoleCode.VENDEUR);
    for (const body of [
      openBody({ action: 'REOPEN' }),
      openBody({ sessionId: randomUUID() }),
      openBody({ status: 'CLOTUREE' }),
    ]) {
      const res = await sync(token, [mutation('CASH_SESSION', body)]);
      expect(res.body.results[0]).toMatchObject({
        status: 'REJETEE',
        code: 'VALIDATION_FAILED',
      });
    }
    expect(
      await prisma.cashSession.count({ where: { userId: authorOf(token) } }),
    ).toBe(0);
  });
});
