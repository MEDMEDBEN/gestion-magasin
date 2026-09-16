import { randomUUID } from 'crypto';
import * as request from 'supertest';
import { RoleCode } from '../src/common/auth.decorators';
import { PrismaService } from '../src/prisma/prisma.service';
import { createE2eApp, createTestUser, E2eApp } from './helpers/e2e-app';

/// Fournisseurs et dettes (P0 n°5). Décisions MEDMEDBEN 2026-09-16 :
/// dette = reprise de l'existant (`openingBalance`, admin) − paiements ; un
/// paiement sort de la caisse ouverte OU se fait hors caisse (virement).
/// Le VENDEUR n'a aucun accès aux fournisseurs (docs/permissions.md).
describe('Fournisseurs et dettes (e2e)', () => {
  let e2e: E2eApp;
  let prisma: PrismaService;
  let server: E2eApp['server'];

  const suffix = Date.now();
  const PASSWORD = 'MotDePasseTemp1!';
  const userIds: string[] = [];
  const supplierIds: string[] = [];
  const tokens: Record<string, string> = {};
  let magasinId = '';

  const as = (token: string) => ({
    get: (url: string) =>
      request(server).get(url).set('Authorization', `Bearer ${token}`),
    post: (url: string) =>
      request(server).post(url).set('Authorization', `Bearer ${token}`),
    patch: (url: string) =>
      request(server).patch(url).set('Authorization', `Bearer ${token}`),
  });

  const createSupplier = async (body: Record<string, unknown>) => {
    const res = await as(tokens.admin)
      .post('/api/suppliers')
      .send({ name: `Fournisseur ${++counter} ${suffix}`, ...body })
      .expect(201);
    supplierIds.push(res.body.id);
    return res.body;
  };
  let counter = 0;

  beforeAll(async () => {
    e2e = await createE2eApp();
    prisma = e2e.prisma;
    server = e2e.server;
    magasinId = (
      await prisma.location.findFirstOrThrow({ where: { type: 'MAGASIN' } })
    ).id;
    for (const [key, role] of [
      ['admin', RoleCode.ADMIN],
      ['magasinier', RoleCode.MAGASINIER],
      ['vendeur', RoleCode.VENDEUR],
    ] as const) {
      const email = `e2e-supplier-${key}-${suffix}@test.local`;
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
    await prisma.auditLog.deleteMany({ where: { userId: { in: userIds } } });
    await prisma.cashMovement.deleteMany({
      where: { userId: { in: userIds } },
    });
    await prisma.supplierPayment.deleteMany({
      where: { supplierId: { in: supplierIds } },
    });
    await prisma.cashSession.deleteMany({ where: { userId: { in: userIds } } });
    await prisma.supplier.deleteMany({ where: { id: { in: supplierIds } } });
    await prisma.user.deleteMany({ where: { id: { in: userIds } } });
    await e2e.app.close();
  });

  describe('fiches', () => {
    it('admin crée avec une reprise de dette ; magasinier lit, ne modifie pas', async () => {
      const supplier = await createSupplier({
        phone: '0550 00 11 22',
        openingBalance: 500000,
        contactName: 'M. Rahmani',
      });
      expect(supplier).toMatchObject({
        openingBalance: 500000,
        balanceDue: 500000,
        paidAmount: 0,
        isActive: true,
      });

      const seen = await as(tokens.magasinier)
        .get(`/api/suppliers/${supplier.id}`)
        .expect(200);
      expect(seen.body.balanceDue).toBe(500000);

      await as(tokens.magasinier)
        .patch(`/api/suppliers/${supplier.id}`)
        .send({ name: 'Renommé' })
        .expect(403);
      await as(tokens.magasinier)
        .post('/api/suppliers')
        .send({ name: `Interdit ${suffix}` })
        .expect(403);
    });

    it('le VENDEUR n’accède à rien (ni liste, ni fiche, ni paiement)', async () => {
      const supplier = await createSupplier({});
      await as(tokens.vendeur).get('/api/suppliers').expect(403);
      await as(tokens.vendeur).get(`/api/suppliers/${supplier.id}`).expect(403);
      await as(tokens.vendeur)
        .post('/api/payments/supplier')
        .send({ supplierId: supplier.id, amount: 100, fromCash: false })
        .expect(403);
    });

    it('recherche par nom et fournisseurs désactivés masqués par défaut', async () => {
      const name = `Sonelec ${suffix}`;
      const supplier = await createSupplier({ name });
      const found = await as(tokens.admin)
        .get(`/api/suppliers?q=sonelec ${suffix}`)
        .expect(200);
      expect(found.body.data.map((s: { id: string }) => s.id)).toContain(
        supplier.id,
      );

      await as(tokens.admin)
        .patch(`/api/suppliers/${supplier.id}`)
        .send({ isActive: false })
        .expect(200);
      const active = await as(tokens.admin)
        .get(`/api/suppliers?q=sonelec ${suffix}`)
        .expect(200);
      expect(active.body.data).toHaveLength(0);
      const all = await as(tokens.admin)
        .get(`/api/suppliers?q=sonelec ${suffix}&includeInactive=true`)
        .expect(200);
      expect(all.body.data).toHaveLength(1);
    });

    it('création et modification auditées (reprise de dette comprise)', async () => {
      const supplier = await createSupplier({ openingBalance: 100000 });
      await as(tokens.admin)
        .patch(`/api/suppliers/${supplier.id}`)
        .send({ openingBalance: 250000 })
        .expect(200);
      const audits = await prisma.auditLog.findMany({
        where: { entityType: 'Supplier', entityId: supplier.id },
        orderBy: { createdAt: 'asc' },
      });
      expect(audits.map((a) => a.action)).toEqual(['CREATE', 'UPDATE']);
      expect(audits[1].oldValue).toMatchObject({ openingBalance: 100000 });
      expect(audits[1].newValue).toMatchObject({ openingBalance: 250000 });
    });
  });

  describe('dette et paiements', () => {
    const openCash = () =>
      as(tokens.admin)
        .post('/api/cash-sessions')
        .send({ locationId: magasinId, openingFloat: 1000000 });

    it('payé par la caisse : SORTIE dans la session, dette réduite', async () => {
      const supplier = await createSupplier({ openingBalance: 500000 });
      const cash = await openCash().expect(201);

      const payment = await as(tokens.admin)
        .post('/api/payments/supplier')
        .send({ supplierId: supplier.id, amount: 300000, fromCash: true })
        .expect(201);
      expect(payment.body).toMatchObject({
        amount: 300000,
        method: 'ESPECES',
        fromCash: true,
        balanceDue: 200000,
      });

      const movement = await prisma.cashMovement.findFirst({
        where: { cashSessionId: cash.body.id, type: 'SORTIE' },
      });
      expect(movement?.amount).toBe(300000);
      expect(movement?.note).toContain(payment.body.id);

      const report = await as(tokens.admin)
        .get(`/api/cash-sessions/${cash.body.id}/report`)
        .expect(200);
      expect(report.body.cashOutAmount).toBe(300000);
      expect(report.body.currentAmount).toBe(700000);

      await as(tokens.admin)
        .post(`/api/cash-sessions/${cash.body.id}/close`)
        .send({ countedAmount: 700000 })
        .expect(200);

      const fiche = await as(tokens.admin)
        .get(`/api/suppliers/${supplier.id}`)
        .expect(200);
      expect(fiche.body).toMatchObject({
        paidAmount: 300000,
        balanceDue: 200000,
      });
    });

    it('payé hors caisse (virement) : aucune écriture de caisse', async () => {
      const supplier = await createSupplier({ openingBalance: 400000 });
      const before = await prisma.cashMovement.count();

      const payment = await as(tokens.admin)
        .post('/api/payments/supplier')
        .send({
          supplierId: supplier.id,
          amount: 400000,
          fromCash: false,
          method: 'VIREMENT',
          note: 'Virement BNA',
        })
        .expect(201);

      expect(payment.body).toMatchObject({
        method: 'VIREMENT',
        fromCash: false,
        balanceDue: 0,
      });
      expect(await prisma.cashMovement.count()).toBe(before);
    });

    it('espèces sans caisse ouverte → CASH_SESSION_REQUIRED, rien n’est écrit', async () => {
      const supplier = await createSupplier({ openingBalance: 100000 });
      const res = await as(tokens.admin)
        .post('/api/payments/supplier')
        .send({ supplierId: supplier.id, amount: 100000, fromCash: true })
        .expect(422);
      expect(res.body.code).toBe('CASH_SESSION_REQUIRED');
      expect(
        await prisma.supplierPayment.count({
          where: { supplierId: supplier.id },
        }),
      ).toBe(0);
    });

    it('caisse insuffisante : la sortie est refusée, le tiroir jamais négatif', async () => {
      const supplier = await createSupplier({ openingBalance: 5000000 });
      const cash = await as(tokens.admin)
        .post('/api/cash-sessions')
        .send({ locationId: magasinId, openingFloat: 100000 })
        .expect(201);

      const res = await as(tokens.admin)
        .post('/api/payments/supplier')
        .send({ supplierId: supplier.id, amount: 500000, fromCash: true })
        .expect(422);
      expect(res.body.code).toBe('CASH_INSUFFICIENT');

      const report = await as(tokens.admin)
        .get(`/api/cash-sessions/${cash.body.id}/report`)
        .expect(200);
      expect(report.body.currentAmount).toBe(100000);
      expect(
        await prisma.supplierPayment.count({
          where: { supplierId: supplier.id },
        }),
      ).toBe(0);
      await as(tokens.admin)
        .post(`/api/cash-sessions/${cash.body.id}/close`)
        .send({ countedAmount: 100000 })
        .expect(200);
    });

    it('renvoi du même id avec un AUTRE montant → 409, rien de plus n’est payé', async () => {
      const supplier = await createSupplier({ openingBalance: 200000 });
      const id = randomUUID();
      await as(tokens.admin)
        .post('/api/payments/supplier')
        .send({ id, supplierId: supplier.id, amount: 50000, fromCash: false })
        .expect(201);
      const res = await as(tokens.admin)
        .post('/api/payments/supplier')
        .send({ id, supplierId: supplier.id, amount: 90000, fromCash: false })
        .expect(409);
      expect(res.body.code).toBe('PAYMENT_ALREADY_RECORDED');
      const fiche = await as(tokens.admin)
        .get(`/api/suppliers/${supplier.id}`)
        .expect(200);
      expect(fiche.body.balanceDue).toBe(150000);
    });

    it('jamais au-delà du reste dû', async () => {
      const supplier = await createSupplier({ openingBalance: 100000 });
      await as(tokens.admin)
        .post('/api/payments/supplier')
        .send({ supplierId: supplier.id, amount: 100001, fromCash: false })
        .expect(422);
      await as(tokens.admin)
        .post('/api/payments/supplier')
        .send({ supplierId: supplier.id, amount: 100000, fromCash: false })
        .expect(201);
      await as(tokens.admin)
        .post('/api/payments/supplier')
        .send({ supplierId: supplier.id, amount: 1, fromCash: false })
        .expect(422);
    });

    it('renvoi du même paiement (même id) : la dette n’est réduite qu’UNE fois', async () => {
      const supplier = await createSupplier({ openingBalance: 200000 });
      const body = {
        id: randomUUID(),
        supplierId: supplier.id,
        amount: 50000,
        fromCash: false,
      };
      const first = await as(tokens.admin)
        .post('/api/payments/supplier')
        .send(body)
        .expect(201);
      const again = await as(tokens.admin)
        .post('/api/payments/supplier')
        .send(body)
        .expect(201);

      expect(again.body.id).toBe(first.body.id);
      expect(again.body.balanceDue).toBe(150000);
      expect(
        await prisma.supplierPayment.count({
          where: { supplierId: supplier.id },
        }),
      ).toBe(1);
    });

    it('la reprise ne peut pas descendre sous ce qui est déjà payé', async () => {
      const supplier = await createSupplier({ openingBalance: 300000 });
      await as(tokens.admin)
        .post('/api/payments/supplier')
        .send({ supplierId: supplier.id, amount: 200000, fromCash: false })
        .expect(201);

      await as(tokens.admin)
        .patch(`/api/suppliers/${supplier.id}`)
        .send({ openingBalance: 100000 })
        .expect(422);
      const fiche = await as(tokens.admin)
        .get(`/api/suppliers/${supplier.id}`)
        .expect(200);
      expect(fiche.body.balanceDue).toBe(100000);
    });

    it('deux paiements simultanés ne dépassent pas la dette', async () => {
      const supplier = await createSupplier({ openingBalance: 100000 });
      const pay = () =>
        as(tokens.admin)
          .post('/api/payments/supplier')
          .send({ supplierId: supplier.id, amount: 100000, fromCash: false });
      const results = await Promise.all([pay(), pay()]);
      expect(results.map((r) => r.status).sort()).toEqual([201, 422]);
    });
  });
});
