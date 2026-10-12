import { randomUUID } from 'crypto';
import * as request from 'supertest';
import { RoleCode } from '../src/common/auth.decorators';
import { PrismaService } from '../src/prisma/prisma.service';
import { createE2eApp, createTestUser, E2eApp } from './helpers/e2e-app';

/// Décisions MEDMEDBEN du 2026-10-12 : remise sur toute la facture (admin et
/// vendeur, jamais sous le coût), profit de chaque vente (coût figé), vente à
/// un fournisseur comme à un confrère.
describe('Remise sur facture, profit, vente à un fournisseur (e2e)', () => {
  let e2e: E2eApp;
  let prisma: PrismaService;
  let server: E2eApp['server'];

  const suffix = Date.now();
  const PASSWORD = 'MotDePasseTemp1!';
  const userIds: string[] = [];
  const productIds: string[] = [];
  const customerIds: string[] = [];
  const supplierIds: string[] = [];
  const tokens: Record<string, string> = {};
  let counter = 0;

  const as = (token: string) => ({
    get: (url: string) =>
      request(server).get(url).set('Authorization', `Bearer ${token}`),
    post: (url: string) =>
      request(server).post(url).set('Authorization', `Bearer ${token}`),
  });

  /// Confrère + produit à 150,00 au tarif par défaut, 10 en stock acheté
  /// 100,00 (coût) : de quoi vendre à crédit, sans caisse.
  const setup = async () => {
    const n = ++counter;
    const confrere = (
      await as(tokens.vendeur)
        .post('/api/confreres')
        .send({ name: `Acheteur ${suffix} ${n}` })
        .expect(201)
    ).body as { id: string; supplierId: string };
    customerIds.push(confrere.id);
    supplierIds.push(confrere.supplierId);
    const product = await prisma.product.create({
      data: {
        sku: `E2E-RP-${suffix}-${n}`,
        barcode: `E2E-RP-${suffix}-${n}`,
        name: `Produit remise ${n}`,
      },
    });
    productIds.push(product.id);
    const tier = await prisma.priceTier.findFirstOrThrow({
      where: { isDefault: true },
    });
    await prisma.productPrice.create({
      data: { productId: product.id, priceTierId: tier.id, priceHt: 15000 },
    });
    await as(tokens.vendeur)
      .post(`/api/confreres/${confrere.id}/deals`)
      .send({
        clientMutationId: randomUUID(),
        receive: [
          { productId: product.id, receivedQuantity: '10', unitPriceHt: 10000 },
        ],
      })
      .expect(201);
    return { customerId: confrere.id, productId: product.id };
  };

  beforeAll(async () => {
    e2e = await createE2eApp();
    prisma = e2e.prisma;
    server = e2e.server;
    for (const [key, role] of [
      ['vendeur', RoleCode.VENDEUR],
      ['magasinier', RoleCode.MAGASINIER],
    ] as const) {
      const email = `e2e-remise-${key}-${suffix}@test.local`;
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
  });

  afterAll(async () => {
    const receptions = await prisma.reception.findMany({
      where: { supplierId: { in: supplierIds } },
      select: { id: true },
    });
    const receptionIds = receptions.map((r) => r.id);
    await prisma.auditLog.deleteMany({ where: { userId: { in: userIds } } });
    await prisma.notification.deleteMany({
      where: { operationId: { in: receptionIds } },
    });
    await prisma.receptionLine.deleteMany({
      where: { receptionId: { in: receptionIds } },
    });
    await prisma.reception.deleteMany({ where: { id: { in: receptionIds } } });
    await prisma.sale.deleteMany({
      where: { customerId: { in: customerIds } },
    });
    await prisma.stockMovement.deleteMany({
      where: { productId: { in: productIds } },
    });
    await prisma.stock.deleteMany({ where: { productId: { in: productIds } } });
    await prisma.productPrice.deleteMany({
      where: { productId: { in: productIds } },
    });
    await prisma.product.deleteMany({ where: { id: { in: productIds } } });
    await prisma.customer.deleteMany({ where: { id: { in: customerIds } } });
    await prisma.supplier.deleteMany({ where: { id: { in: supplierIds } } });
    await prisma.user.deleteMany({ where: { id: { in: userIds } } });
    await e2e.app.close();
  });

  it('remise sur facture par le VENDEUR : répartie, tracée, profit juste', async () => {
    const { customerId, productId } = await setup();
    const res = await as(tokens.vendeur)
      .post('/api/sales')
      .send({
        clientMutationId: randomUUID(),
        customerId,
        lines: [{ productId, quantity: '2' }],
        paidAmount: 0,
        discountAmount: 2000,
        expectedTotalTtc: 28000,
      })
      .expect(201);
    expect(res.body).toMatchObject({
      totalTtc: 28000,
      discountAmount: 2000,
      // 280,00 vendus − 2 × 100,00 de coût figé.
      profitHt: 8000,
    });
    expect(res.body.lines[0]).toMatchObject({
      discountAmount: 2000,
      costHt: 10000,
    });
  });

  it('remise sur facture sous le coût → 422 PRICE_BELOW_COST', async () => {
    const { customerId, productId } = await setup();
    const res = await as(tokens.vendeur)
      .post('/api/sales')
      .send({
        clientMutationId: randomUUID(),
        customerId,
        lines: [{ productId, quantity: '2' }],
        paidAmount: 0,
        // Marge disponible : 2 × (150 − 100) = 100,00.
        discountAmount: 10001,
      })
      .expect(422);
    expect(res.body.code).toBe('PRICE_BELOW_COST');
  });

  it('vendre à un fournisseur : une seule fiche client liée ; magasinier 403', async () => {
    const supplier = await prisma.supplier.create({
      data: { name: `Fournisseur acheteur ${suffix}`, phone: '0550' },
    });
    supplierIds.push(supplier.id);
    const list = (
      await as(tokens.vendeur).get('/api/confreres/suppliers').expect(200)
    ).body as { id: string }[];
    expect(list.map((s) => s.id)).toContain(supplier.id);

    const first = (
      await as(tokens.vendeur)
        .post(`/api/confreres/suppliers/${supplier.id}/customer`)
        .expect(201)
    ).body as { customerId: string };
    customerIds.push(first.customerId);
    const again = (
      await as(tokens.vendeur)
        .post(`/api/confreres/suppliers/${supplier.id}/customer`)
        .expect(201)
    ).body as { customerId: string };
    expect(again.customerId).toBe(first.customerId);
    const customer = await prisma.customer.findUniqueOrThrow({
      where: { id: first.customerId },
    });
    expect(customer.supplierId).toBe(supplier.id);

    await as(tokens.magasinier).get('/api/confreres/suppliers').expect(403);
  });
});
