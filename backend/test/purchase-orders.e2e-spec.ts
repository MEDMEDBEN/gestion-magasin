import { randomUUID } from 'crypto';
import * as request from 'supertest';
import { RoleCode } from '../src/common/auth.decorators';
import { PrismaService } from '../src/prisma/prisma.service';
import { createE2eApp, createTestUser, E2eApp } from './helpers/e2e-app';

/// Commandes fournisseurs (P0 n°6). Décision MEDMEDBEN 2026-09-16 : la DETTE
/// fournisseur ne bouge PAS à la commande — elle suivra les réceptions (P0 #7).
/// Création/modification : ADMIN + MAGASINIER ; confirmation/annulation : ADMIN.
describe('Commandes fournisseurs (e2e)', () => {
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
  let productId = '';
  let counter = 0;

  const as = (token: string) => ({
    get: (url: string) =>
      request(server).get(url).set('Authorization', `Bearer ${token}`),
    post: (url: string) =>
      request(server).post(url).set('Authorization', `Bearer ${token}`),
    patch: (url: string) =>
      request(server).patch(url).set('Authorization', `Bearer ${token}`),
  });

  /// Produit taxé à 19 % (le taux est figé sur la ligne de commande).
  const product = async () => {
    const n = ++counter;
    const tva = await prisma.taxRate.findFirstOrThrow({ where: { rate: 19 } });
    const created = await prisma.product.create({
      data: {
        sku: `E2E-BC-${suffix}-${n}`,
        barcode: `E2E-BC-BC-${suffix}-${n}`,
        name: `Produit achat ${n}`,
        taxRateId: tva.id,
      },
    });
    productIds.push(created.id);
    return created.id;
  };

  const order = async (
    token = tokens.magasinier,
    body: Record<string, unknown> = {},
  ) => {
    const res = await as(token)
      .post('/api/purchase-orders')
      .send({
        supplierId,
        lines: [{ productId, orderedQuantity: '100', unitPriceHt: 120000 }],
        ...body,
      })
      .expect(201);
    orderIds.push(res.body.id);
    return res.body;
  };

  beforeAll(async () => {
    e2e = await createE2eApp();
    prisma = e2e.prisma;
    server = e2e.server;
    for (const [key, role] of [
      ['admin', RoleCode.ADMIN],
      ['magasinier', RoleCode.MAGASINIER],
      ['vendeur', RoleCode.VENDEUR],
    ] as const) {
      const email = `e2e-purchase-${key}-${suffix}@test.local`;
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
      data: { name: `Fournisseur achats ${suffix}` },
    });
    supplierIds.push(supplier.id);
    supplierId = supplier.id;
    productId = await product();
  });

  afterAll(async () => {
    await prisma.auditLog.deleteMany({ where: { userId: { in: userIds } } });
    await prisma.purchaseOrder.deleteMany({ where: { id: { in: orderIds } } });
    await prisma.product.deleteMany({ where: { id: { in: productIds } } });
    await prisma.supplier.deleteMany({ where: { id: { in: supplierIds } } });
    await prisma.user.deleteMany({ where: { id: { in: userIds } } });
    await e2e.app.close();
  });

  describe('création', () => {
    it('numéro BC-AAAA-NNNNN, TVA figée, totaux justes, dette inchangée', async () => {
      const before = (
        await as(tokens.admin).get(`/api/suppliers/${supplierId}`).expect(200)
      ).body.balanceDue;

      const created = await order();

      expect(created.number).toMatch(/^BC-\d{4}-\d{5}$/);
      expect(created.status).toBe('BROUILLON');
      // 100 × 1 200,00 HT = 120 000,00 ; TVA 19 % = 22 800,00 ; TTC = 142 800,00
      expect(created.totalHt).toBe(12000000);
      expect(created.totalTax).toBe(2280000);
      expect(created.totalTtc).toBe(14280000);
      expect(created.lines[0]).toMatchObject({
        orderedQuantity: '100.000',
        receivedQuantity: '0.000',
        remainingQuantity: '100.000',
        taxRate: '19.00',
      });

      // La commande n'est PAS une dette : rien n'est reçu.
      const after = (
        await as(tokens.admin).get(`/api/suppliers/${supplierId}`).expect(200)
      ).body.balanceDue;
      expect(after).toBe(before);
    });

    it('numéros consécutifs même en créant en parallèle', async () => {
      const created = await Promise.all([
        as(tokens.admin)
          .post('/api/purchase-orders')
          .send({
            supplierId,
            lines: [{ productId, orderedQuantity: '1', unitPriceHt: 1000 }],
          }),
        as(tokens.admin)
          .post('/api/purchase-orders')
          .send({
            supplierId,
            lines: [{ productId, orderedQuantity: '1', unitPriceHt: 1000 }],
          }),
      ]);
      for (const res of created) {
        expect(res.status).toBe(201);
        orderIds.push(res.body.id);
      }
      const numbers = created
        .map((r) => Number(r.body.number.slice(-5)))
        .sort((a, b) => a - b);
      expect(new Set(numbers).size).toBe(2);
      expect(numbers[1] - numbers[0]).toBe(1);
    });

    it('renvoi du même id : UNE seule commande', async () => {
      const id = randomUUID();
      const body = {
        id,
        supplierId,
        lines: [{ productId, orderedQuantity: '5', unitPriceHt: 1000 }],
      };
      const first = await as(tokens.magasinier)
        .post('/api/purchase-orders')
        .send(body)
        .expect(201);
      orderIds.push(id);
      const again = await as(tokens.magasinier)
        .post('/api/purchase-orders')
        .send(body)
        .expect(201);
      expect(again.body.number).toBe(first.body.number);
      expect(await prisma.purchaseOrder.count({ where: { id } })).toBe(1);
    });

    it('refus : vendeur, fournisseur inactif, produit inactif, quantité nulle', async () => {
      await as(tokens.vendeur)
        .post('/api/purchase-orders')
        .send({
          supplierId,
          lines: [{ productId, orderedQuantity: '1', unitPriceHt: 1000 }],
        })
        .expect(403);

      const off = await prisma.supplier.create({
        data: { name: `Inactif ${suffix}`, isActive: false },
      });
      supplierIds.push(off.id);
      await as(tokens.admin)
        .post('/api/purchase-orders')
        .send({
          supplierId: off.id,
          lines: [{ productId, orderedQuantity: '1', unitPriceHt: 1000 }],
        })
        .expect(422);

      const hidden = await product();
      await prisma.product.update({
        where: { id: hidden },
        data: { isActive: false },
      });
      await as(tokens.admin)
        .post('/api/purchase-orders')
        .send({
          supplierId,
          lines: [
            { productId: hidden, orderedQuantity: '1', unitPriceHt: 1000 },
          ],
        })
        .expect(422);

      await as(tokens.admin)
        .post('/api/purchase-orders')
        .send({
          supplierId,
          lines: [{ productId, orderedQuantity: '0', unitPriceHt: 1000 }],
        })
        .expect(422);
    });
  });

  describe('cycle de vie', () => {
    it('modification (lignes remplacées) puis envoi au fournisseur', async () => {
      const created = await order();
      const updated = await as(tokens.magasinier)
        .patch(`/api/purchase-orders/${created.id}`)
        .send({
          status: 'COMMANDEE',
          lines: [
            { productId, orderedQuantity: '10', unitPriceHt: 100000 },
            { productId, orderedQuantity: '5', unitPriceHt: 100000 },
          ],
        })
        .expect(200);

      expect(updated.body.status).toBe('COMMANDEE');
      expect(updated.body.lines).toHaveLength(2);
      expect(updated.body.totalHt).toBe(1500000);
    });

    it('confirmation ADMIN seule, idempotente, puis modification refusée', async () => {
      const created = await order();
      await as(tokens.magasinier)
        .post(`/api/purchase-orders/${created.id}/confirm`)
        .expect(403);

      const confirmed = await as(tokens.admin)
        .post(`/api/purchase-orders/${created.id}/confirm`)
        .expect(200);
      expect(confirmed.body).toMatchObject({ status: 'CONFIRMEE' });
      expect(confirmed.body.confirmedAt).toBeTruthy();

      const again = await as(tokens.admin)
        .post(`/api/purchase-orders/${created.id}/confirm`)
        .expect(200);
      expect(again.body.confirmedAt).toBe(confirmed.body.confirmedAt);
      expect(
        await prisma.auditLog.count({
          where: { entityId: created.id, action: 'VALIDATE' },
        }),
      ).toBe(1);

      const refused = await as(tokens.admin)
        .patch(`/api/purchase-orders/${created.id}`)
        .send({
          lines: [{ productId, orderedQuantity: '1', unitPriceHt: 100 }],
        })
        .expect(409);
      expect(refused.body.code).toBe('INVALID_STATE_TRANSITION');
    });

    it('annulation ADMIN : statut ANNULEE, auditée, jamais deux fois', async () => {
      const created = await order();
      await as(tokens.magasinier)
        .post(`/api/purchase-orders/${created.id}/cancel`)
        .expect(403);

      const cancelled = await as(tokens.admin)
        .post(`/api/purchase-orders/${created.id}/cancel`)
        .expect(200);
      expect(cancelled.body.status).toBe('ANNULEE');
      await as(tokens.admin)
        .post(`/api/purchase-orders/${created.id}/cancel`)
        .expect(409);
      expect(
        await prisma.auditLog.count({
          where: { entityId: created.id, action: 'CANCEL' },
        }),
      ).toBe(1);
    });

    it('deux confirmations simultanées : une seule écrit l’audit', async () => {
      const created = await order();
      const results = await Promise.all([
        as(tokens.admin).post(`/api/purchase-orders/${created.id}/confirm`),
        as(tokens.admin).post(`/api/purchase-orders/${created.id}/confirm`),
      ]);
      expect(results.map((r) => r.status)).toEqual([200, 200]);
      expect(
        await prisma.auditLog.count({
          where: { entityId: created.id, action: 'VALIDATE' },
        }),
      ).toBe(1);
    });
  });

  it('liste : filtres statut et fournisseur, magasinier autorisé', async () => {
    const created = await order();
    await as(tokens.admin)
      .post(`/api/purchase-orders/${created.id}/cancel`)
      .expect(200);

    const list = await as(tokens.magasinier)
      .get(
        `/api/purchase-orders?supplierId=${supplierId}&status=ANNULEE&limit=200`,
      )
      .expect(200);
    const ids = list.body.data.map((o: { id: string }) => o.id);
    expect(ids).toContain(created.id);
    expect(
      list.body.data.every((o: { status: string }) => o.status === 'ANNULEE'),
    ).toBe(true);

    await as(tokens.vendeur).get('/api/purchase-orders').expect(403);
  });
});
