import { randomUUID } from 'crypto';
import * as request from 'supertest';
import { RoleCode } from '../src/common/auth.decorators';
import { PrismaService } from '../src/prisma/prisma.service';
import { createE2eApp, createTestUser, E2eApp } from './helpers/e2e-app';

/// Confrères (décision MEDMEDBEN 2026-10-08) : admin + vendeur ; achat et
/// échange en une transaction ; dette sans plafond des deux côtés.
describe('Confrères (e2e)', () => {
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
  let counter = 0;

  const as = (token: string) => ({
    get: (url: string) =>
      request(server).get(url).set('Authorization', `Bearer ${token}`),
    post: (url: string) =>
      request(server).post(url).set('Authorization', `Bearer ${token}`),
  });

  const product = async () => {
    const n = ++counter;
    const created = await prisma.product.create({
      data: {
        sku: `E2E-CF-${suffix}-${n}`,
        barcode: `E2E-CF-${suffix}-${n}`,
        name: `Produit confrère ${n}`,
      },
    });
    productIds.push(created.id);
    return created.id;
  };

  const stockOf = async (productId: string) =>
    (
      await prisma.stock.findFirst({
        where: { productId, locationId: magasinId },
      })
    )?.quantity.toFixed(3) ?? '0.000';

  const confrere = async () => {
    const res = await as(tokens.vendeur)
      .post('/api/confreres')
      .send({ name: `Confrère ${suffix} ${++counter}`, phone: '0555' })
      .expect(201);
    customerIds.push(res.body.id);
    return res.body as { id: string; supplierId: string };
  };

  const row = async (id: string) =>
    (
      (await as(tokens.vendeur).get('/api/confreres').expect(200)).body as {
        id: string;
        theyOwe: number;
        weOwe: number;
        net: number;
      }[]
    ).find((c) => c.id === id)!;

  beforeAll(async () => {
    e2e = await createE2eApp();
    prisma = e2e.prisma;
    server = e2e.server;
    for (const [key, role] of [
      ['vendeur', RoleCode.VENDEUR],
      ['magasinier', RoleCode.MAGASINIER],
    ] as const) {
      const email = `e2e-confrere-${key}-${suffix}@test.local`;
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
    magasinId = (
      await prisma.location.findFirstOrThrow({ where: { type: 'MAGASIN' } })
    ).id;
  });

  afterAll(async () => {
    const customers = await prisma.customer.findMany({
      where: { id: { in: customerIds } },
      select: { supplierId: true },
    });
    const supplierIds = customers.flatMap((c) =>
      c.supplierId ? [c.supplierId] : [],
    );
    const receptions = await prisma.reception.findMany({
      where: { supplierId: { in: supplierIds } },
      select: { id: true },
    });
    await prisma.auditLog.deleteMany({ where: { userId: { in: userIds } } });
    await prisma.notification.deleteMany({
      where: { operationId: { in: receptions.map((r) => r.id) } },
    });
    await prisma.receptionLine.deleteMany({
      where: { receptionId: { in: receptions.map((r) => r.id) } },
    });
    await prisma.reception.deleteMany({
      where: { id: { in: receptions.map((r) => r.id) } },
    });
    await prisma.sale.deleteMany({
      where: { customerId: { in: customerIds } },
    });
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

  it('le magasinier n’a pas accès aux confrères (403)', async () => {
    await as(tokens.magasinier).get('/api/confreres').expect(403);
    await as(tokens.magasinier)
      .post('/api/confreres')
      .send({ name: 'Interdit' })
      .expect(403);
  });

  it('achat par le VENDEUR : stock au magasin, « je lui dois », rejeu sans second effet', async () => {
    const c = await confrere();
    const p = await product();
    const body = {
      clientMutationId: randomUUID(),
      receive: [{ productId: p, receivedQuantity: '10', unitPriceHt: 10000 }],
    };
    const first = await as(tokens.vendeur)
      .post(`/api/confreres/${c.id}/deals`)
      .send(body)
      .expect(201);
    expect(first.body.saleNumber).toBeNull();
    expect(first.body.confrere).toMatchObject({
      theyOwe: 0,
      weOwe: 100000,
      net: -100000,
    });
    const again = await as(tokens.vendeur)
      .post(`/api/confreres/${c.id}/deals`)
      .send(body)
      .expect(201);
    expect(again.body.receptionNumber).toBe(first.body.receptionNumber);
    expect(await stockOf(p)).toBe('10.000');
  });

  it('échange : achat + vente à crédit SANS plafond ni échéance, solde net', async () => {
    const c = await confrere();
    const mine = await product();
    const theirs = await product();
    // Mon stock à donner : acheté d'abord chez lui.
    await as(tokens.vendeur)
      .post(`/api/confreres/${c.id}/deals`)
      .send({
        clientMutationId: randomUUID(),
        receive: [
          { productId: mine, receivedQuantity: '5', unitPriceHt: 10000 },
        ],
      })
      .expect(201);
    const res = await as(tokens.vendeur)
      .post(`/api/confreres/${c.id}/deals`)
      .send({
        clientMutationId: randomUUID(),
        saleMutationId: randomUUID(),
        receive: [
          { productId: theirs, receivedQuantity: '2', unitPriceHt: 5000 },
        ],
        give: [
          {
            productId: mine,
            quantity: '3',
            unitPriceHt: 15000,
            priceEdited: true,
          },
        ],
      })
      .expect(201);
    expect(res.body.saleNumber).toEqual(expect.any(String));
    expect(res.body.confrere).toMatchObject({
      theyOwe: 45000,
      weOwe: 60000,
      net: -15000,
    });
    expect(await stockOf(mine)).toBe('2.000');
    expect(await stockOf(theirs)).toBe('2.000');
    const sale = await prisma.sale.findFirstOrThrow({
      where: { number: res.body.saleNumber },
    });
    expect(sale.dueDate).toBeNull();
  });

  it('échange impossible (stock insuffisant) : RIEN n’est enregistré', async () => {
    const c = await confrere();
    const mine = await product();
    const theirs = await product();
    await as(tokens.vendeur)
      .post(`/api/confreres/${c.id}/deals`)
      .send({
        clientMutationId: randomUUID(),
        saleMutationId: randomUUID(),
        receive: [
          { productId: theirs, receivedQuantity: '2', unitPriceHt: 5000 },
        ],
        give: [{ productId: mine, quantity: '1', unitPriceHt: 15000 }],
      })
      .expect((r) => expect(r.status).toBeGreaterThanOrEqual(400));
    expect(await stockOf(theirs)).toBe('0.000');
    expect(await row(c.id)).toMatchObject({ theyOwe: 0, weOwe: 0 });
  });

  it('vente au panier à un confrère : crédit au-delà du plafond (0), sans échéance', async () => {
    const c = await confrere();
    const p = await product();
    await as(tokens.vendeur)
      .post(`/api/confreres/${c.id}/deals`)
      .send({
        clientMutationId: randomUUID(),
        receive: [{ productId: p, receivedQuantity: '4', unitPriceHt: 10000 }],
      })
      .expect(201);
    await as(tokens.vendeur)
      .post('/api/sales')
      .send({
        clientMutationId: randomUUID(),
        customerId: c.id,
        lines: [
          {
            productId: p,
            quantity: '1',
            unitPriceHt: 12000,
            priceEdited: true,
          },
        ],
        paidAmount: 0,
      })
      .expect(201);
    expect(await row(c.id)).toMatchObject({ theyOwe: 12000, weOwe: 40000 });
  });

  it('audit sécu : le VENDEUR n’abaisse pas le coût (plancher de vente) par un achat', async () => {
    const c = await confrere();
    const p = await product();
    await as(tokens.vendeur)
      .post(`/api/confreres/${c.id}/deals`)
      .send({
        clientMutationId: randomUUID(),
        receive: [{ productId: p, receivedQuantity: '2', unitPriceHt: 10000 }],
      })
      .expect(201);
    const res = await as(tokens.vendeur)
      .post(`/api/confreres/${c.id}/deals`)
      .send({
        clientMutationId: randomUUID(),
        receive: [{ productId: p, receivedQuantity: '0.001', unitPriceHt: 1 }],
      })
      .expect(422);
    expect(res.body.code).toBe('PRICE_BELOW_COST');
    const product_ = await prisma.product.findUniqueOrThrow({
      where: { id: p },
    });
    expect(product_.lastPurchasePriceHt).toBe(10000);
  });

  it('fournisseur lié désactivé : le plafond de crédit revient', async () => {
    const c = await confrere();
    const p = await product();
    await as(tokens.vendeur)
      .post(`/api/confreres/${c.id}/deals`)
      .send({
        clientMutationId: randomUUID(),
        receive: [{ productId: p, receivedQuantity: '1', unitPriceHt: 10000 }],
      })
      .expect(201);
    await prisma.supplier.update({
      where: { id: c.supplierId },
      data: { isActive: false },
    });
    await as(tokens.vendeur)
      .post('/api/sales')
      .send({
        clientMutationId: randomUUID(),
        customerId: c.id,
        lines: [
          {
            productId: p,
            quantity: '1',
            unitPriceHt: 12000,
            priceEdited: true,
          },
        ],
        paidAmount: 0,
        dueDate: '2099-01-01',
      })
      .expect(422);
  });

  it('un client ordinaire n’est pas un confrère (404)', async () => {
    const plain = await prisma.customer.create({
      data: { name: `Client ${suffix}` },
    });
    customerIds.push(plain.id);
    await as(tokens.vendeur)
      .post(`/api/confreres/${plain.id}/deals`)
      .send({
        clientMutationId: randomUUID(),
        receive: [
          {
            productId: await product(),
            receivedQuantity: '1',
            unitPriceHt: 100,
          },
        ],
      })
      .expect(404);
  });
});
