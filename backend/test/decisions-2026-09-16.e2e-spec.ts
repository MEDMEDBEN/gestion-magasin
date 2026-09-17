import { randomUUID } from 'crypto';
import * as request from 'supertest';
import { RoleCode } from '../src/common/auth.decorators';
import { PrismaService } from '../src/prisma/prisma.service';
import { createE2eApp, createTestUser, E2eApp } from './helpers/e2e-app';

/// Décisions validées par MEDMEDBEN le 2026-09-16 (revue générale) :
/// - liste des caisses pour l'admin ;
/// - échéance obligatoire sur toute vente à crédit, montant en retard par client ;
/// - annulation d'un paiement PAR CONTRE-PASSATION, jamais par suppression.
describe('Caisses admin, échéances, contre-passations (e2e)', () => {
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
  let magasinId = '';
  let productId = '';

  const as = (token: string) => ({
    get: (url: string) =>
      request(server).get(url).set('Authorization', `Bearer ${token}`),
    post: (url: string) =>
      request(server).post(url).set('Authorization', `Bearer ${token}`),
  });

  const today = () =>
    new Intl.DateTimeFormat('en-CA', {
      timeZone: 'Africa/Algiers',
      year: 'numeric',
      month: '2-digit',
      day: '2-digit',
    }).format(new Date());

  const openCash = async (token: string, float = 0) =>
    (
      await as(token)
        .post('/api/cash-sessions')
        .send({ locationId: magasinId, openingFloat: float })
        .expect(201)
    ).body;

  const closeCash = (token: string, id: string, counted: number) =>
    as(token)
      .post(`/api/cash-sessions/${id}/close`)
      .send({ countedAmount: counted })
      .expect(200);

  beforeAll(async () => {
    e2e = await createE2eApp();
    prisma = e2e.prisma;
    server = e2e.server;
    magasinId = (
      await prisma.location.findFirstOrThrow({ where: { type: 'MAGASIN' } })
    ).id;
    for (const [key, role] of [
      ['admin', RoleCode.ADMIN],
      ['vendeur', RoleCode.VENDEUR],
    ] as const) {
      const email = `e2e-decisions-${key}-${suffix}@test.local`;
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
    const detail = await prisma.priceTier.findUniqueOrThrow({
      where: { code: 'DETAIL' },
    });
    const product = await prisma.product.create({
      data: {
        sku: `E2E-DEC-${suffix}`,
        barcode: `E2E-DEC-BC-${suffix}`,
        name: 'Produit décisions',
        prices: { create: [{ priceTierId: detail.id, priceHt: 100000 }] },
      },
    });
    productIds.push(product.id);
    productId = product.id;
    await prisma.stock.create({
      data: { productId, locationId: magasinId, quantity: '1000' },
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
    // Contre-passations d'abord (elles référencent l'original).
    await prisma.customerPayment.deleteMany({
      where: {
        customerId: { in: customerIds },
        reversesPaymentId: { not: null },
      },
    });
    await prisma.customerPayment.deleteMany({
      where: { customerId: { in: customerIds } },
    });
    await prisma.supplierPayment.deleteMany({
      where: {
        supplierId: { in: supplierIds },
        reversesPaymentId: { not: null },
      },
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

  describe('liste des caisses (ADMIN)', () => {
    it('toutes les caisses avec caissier et rapport Z ; filtres ; refusée au vendeur', async () => {
      const mine = await openCash(tokens.vendeur, 20000);
      await closeCash(tokens.vendeur, mine.id, 19000);

      const list = await as(tokens.admin)
        .get(`/api/cash-sessions?userId=${userIds[1]}&status=CLOTUREE`)
        .expect(200);
      const row = list.body.data.find((s: { id: string }) => s.id === mine.id);
      expect(row).toMatchObject({
        status: 'CLOTUREE',
        expectedAmount: 20000,
        countedAmount: 19000,
        difference: -1000,
        userFullName: expect.any(String),
      });
      expect(
        list.body.data.every(
          (s: { status: string }) => s.status === 'CLOTUREE',
        ),
      ).toBe(true);

      await as(tokens.vendeur).get('/api/cash-sessions').expect(403);
      await as(tokens.admin)
        .get('/api/cash-sessions?from=2026-02-30')
        .expect(400);
    });
  });

  describe('échéance des ventes à crédit', () => {
    const creditCustomer = async () => {
      const c = await prisma.customer.create({
        data: {
          name: `Client échéance ${randomUUID()}`,
          creditLimit: 10_000_000,
        },
      });
      customerIds.push(c.id);
      return c.id;
    };

    it('obligatoire à crédit, interdite si soldée, jamais dans le passé', async () => {
      const customerId = await creditCustomer();
      const credit = {
        customerId,
        lines: [{ productId, quantity: '1' }],
        paidAmount: 0,
      };

      const missing = await as(tokens.admin)
        .post('/api/sales')
        .send(credit)
        .expect(422);
      expect(missing.body.message).toContain('dueDate');
      await as(tokens.admin)
        .post('/api/sales')
        .send({ ...credit, dueDate: '2020-01-01' })
        .expect(422);
      const ok = await as(tokens.admin)
        .post('/api/sales')
        .send({ ...credit, dueDate: today() })
        .expect(201);
      expect(ok.body.dueDate).toBeTruthy();

      const cash = await openCash(tokens.admin);
      await as(tokens.admin)
        .post('/api/sales')
        .send({
          lines: [{ productId, quantity: '1' }],
          paidAmount: 100000,
          dueDate: today(),
        })
        .expect(422);
      await closeCash(tokens.admin, cash.id, 0);
    });

    it('fiche client : montant EN RETARD = reste dû des ventes échues', async () => {
      const customerId = await creditCustomer();
      await as(tokens.admin)
        .post('/api/sales')
        .send({
          customerId,
          lines: [{ productId, quantity: '1' }],
          paidAmount: 0,
          dueDate: '2099-01-01',
        })
        .expect(201);
      const late = await as(tokens.admin)
        .post('/api/sales')
        .send({
          customerId,
          lines: [{ productId, quantity: '2' }],
          paidAmount: 0,
          dueDate: today(),
        })
        .expect(201);
      // Échéance dépassée (simulée : la vente date d'hier).
      await prisma.sale.update({
        where: { id: late.body.id },
        data: { dueDate: new Date(Date.now() - 86_400_000) },
      });

      const fiche = await as(tokens.admin)
        .get(`/api/customers/${customerId}`)
        .expect(200);
      expect(fiche.body).toMatchObject({
        balanceDue: 300000,
        overdueAmount: 200000,
      });
      const list = await as(tokens.admin)
        .get(`/api/customers?q=${encodeURIComponent(fiche.body.name)}`)
        .expect(200);
      expect(list.body.data[0].overdueAmount).toBe(200000);
    });
  });

  describe('contre-passation des paiements', () => {
    it('règlement client : dette revenue, espèces rendues, original intact, une seule fois, rejouable', async () => {
      const customer = await prisma.customer.create({
        data: {
          name: `Client contre-passation ${suffix}`,
          creditLimit: 1_000_000,
        },
      });
      customerIds.push(customer.id);
      await as(tokens.admin)
        .post('/api/sales')
        .send({
          customerId: customer.id,
          lines: [{ productId, quantity: '1' }],
          paidAmount: 0,
          dueDate: '2099-01-01',
        })
        .expect(201);
      const cash = await openCash(tokens.admin);
      const payment = (
        await as(tokens.admin)
          .post('/api/payments/customer')
          .send({ customerId: customer.id, amount: 30000 })
          .expect(201)
      ).body;
      expect(payment.balanceDue).toBe(70000);

      await as(tokens.vendeur)
        .post(`/api/payments/customer/${payment.id}/reverse`)
        .send({ reason: 'Erreur de saisie' })
        .expect(403);

      const reverse = {
        clientMutationId: randomUUID(),
        reason: 'Montant saisi par erreur',
      };
      const reversal = await as(tokens.admin)
        .post(`/api/payments/customer/${payment.id}/reverse`)
        .send(reverse)
        .expect(201);
      expect(reversal.body).toMatchObject({
        amount: -30000,
        reversesPaymentId: payment.id,
        balanceDue: 100000,
      });
      // Rejeu (réponse perdue) : même résultat, pas de seconde écriture.
      const again = await as(tokens.admin)
        .post(`/api/payments/customer/${payment.id}/reverse`)
        .send(reverse)
        .expect(201);
      expect(again.body.id).toBe(reversal.body.id);
      // Nouvelle tentative (autre clé) : refusée, un règlement ne s'annule qu'une fois.
      await as(tokens.admin)
        .post(`/api/payments/customer/${payment.id}/reverse`)
        .send({ reason: 'Encore' })
        .expect(409);
      await as(tokens.admin)
        .post(`/api/payments/customer/${reversal.body.id}/reverse`)
        .send({ reason: 'Annuler l’annulation' })
        .expect(409);

      const history = await as(tokens.admin)
        .get(`/api/customers/${customer.id}/payments`)
        .expect(200);
      expect(history.body.data).toHaveLength(2);
      const original = history.body.data.find(
        (p: { id: string }) => p.id === payment.id,
      );
      expect(original).toMatchObject({
        amount: 30000,
        reversedById: reversal.body.id,
      });
      const report = await as(tokens.admin)
        .get(`/api/cash-sessions/${cash.id}/report`)
        .expect(200);
      expect(report.body.currentAmount).toBe(0);
      expect(
        await prisma.auditLog.count({
          where: { entityId: payment.id, action: 'CANCEL' },
        }),
      ).toBe(1);
      await closeCash(tokens.admin, cash.id, 0);
    });

    it('règlement client : tiroir insuffisant → refusé (garde de caisse commun)', async () => {
      const customer = await prisma.customer.create({
        data: { name: `Client tiroir ${suffix}`, creditLimit: 1_000_000 },
      });
      customerIds.push(customer.id);
      await as(tokens.admin)
        .post('/api/sales')
        .send({
          customerId: customer.id,
          lines: [{ productId, quantity: '1' }],
          paidAmount: 0,
          dueDate: '2099-01-01',
        })
        .expect(201);
      const first = await openCash(tokens.admin);
      const payment = (
        await as(tokens.admin)
          .post('/api/payments/customer')
          .send({ customerId: customer.id, amount: 50000 })
          .expect(201)
      ).body;
      await closeCash(tokens.admin, first.id, 50000);
      const empty = await openCash(tokens.admin, 0);

      const refused = await as(tokens.admin)
        .post(`/api/payments/customer/${payment.id}/reverse`)
        .send({ reason: 'Erreur' })
        .expect(422);
      expect(refused.body.code).toBe('CASH_INSUFFICIENT');
      await closeCash(tokens.admin, empty.id, 0);
    });

    it('paiement fournisseur : en caisse les espèces rentrent, hors caisse rien ne bouge', async () => {
      const supplier = await prisma.supplier.create({
        data: {
          name: `Fournisseur contre-passation ${suffix}`,
          openingBalance: 500000,
        },
      });
      supplierIds.push(supplier.id);
      const cash = await openCash(tokens.admin, 100000);
      const fromCash = (
        await as(tokens.admin)
          .post('/api/payments/supplier')
          .send({ supplierId: supplier.id, amount: 80000, fromCash: true })
          .expect(201)
      ).body;
      const transfer = (
        await as(tokens.admin)
          .post('/api/payments/supplier')
          .send({ supplierId: supplier.id, amount: 100000, fromCash: false })
          .expect(201)
      ).body;
      expect(transfer.balanceDue).toBe(320000);

      const r1 = await as(tokens.admin)
        .post(`/api/payments/supplier/${fromCash.id}/reverse`)
        .send({ reason: 'Mauvais fournisseur' })
        .expect(201);
      expect(r1.body).toMatchObject({
        amount: -80000,
        fromCash: true,
        balanceDue: 400000,
      });
      const movements = await prisma.cashMovement.count({
        where: { cashSessionId: cash.id },
      });
      const r2 = await as(tokens.admin)
        .post(`/api/payments/supplier/${transfer.id}/reverse`)
        .send({ reason: 'Virement rejeté par la banque' })
        .expect(201);
      expect(r2.body).toMatchObject({
        amount: -100000,
        fromCash: false,
        balanceDue: 500000,
      });
      expect(
        await prisma.cashMovement.count({ where: { cashSessionId: cash.id } }),
      ).toBe(movements);
      const report = await as(tokens.admin)
        .get(`/api/cash-sessions/${cash.id}/report`)
        .expect(200);
      expect(report.body.currentAmount).toBe(100000);
      await closeCash(tokens.admin, cash.id, 100000);
    });
  });
});
