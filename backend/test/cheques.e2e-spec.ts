import { randomUUID } from 'crypto';
import * as request from 'supertest';
import { RoleCode } from '../src/common/auth.decorators';
import { PrismaService } from '../src/prisma/prisma.service';
import { createE2eApp, createTestUser, E2eApp } from './helpers/e2e-app';

/// Suivi des chèques (P1 bis n°21n, décisions MEDMEDBEN 2026-09-28).
///
/// Éprouvé : un chèque ne touche AUCUNE caisse ; la dette baisse dès la
/// remise ; le vendeur saisit, l'ADMIN statue ; un rejet contre-passe (la
/// dette revient) et alerte ; une décision ne se prend qu'une fois.
describe('Chèques (e2e)', () => {
  let e2e: E2eApp;
  let prisma: PrismaService;
  let server: E2eApp['server'];

  const suffix = Date.now();
  const PASSWORD = 'MotDePasseTemp1!';
  const tokens: Record<string, string> = {};
  const ids: Record<string, string> = {};
  const customerIds: string[] = [];
  const supplierIds: string[] = [];
  let magasinId = '';
  let counter = 0;

  const as = (token: string) => ({
    get: (url: string) =>
      request(server).get(url).set('Authorization', `Bearer ${token}`),
    post: (url: string) =>
      request(server).post(url).set('Authorization', `Bearer ${token}`),
  });
  const cheque = (n: string) => ({ number: n, bank: 'BNA Alger' });

  /// Client avec une vente à crédit de 1 000,00 (écrite en base : ici on
  /// éprouve le règlement, pas la vente).
  const indebted = async () => {
    const customer = await prisma.customer.create({
      data: { name: `Client chèque ${suffix}-${++counter}`, creditLimit: 0 },
    });
    customerIds.push(customer.id);
    await prisma.sale.create({
      data: {
        number: `E2E-CHQ-${suffix}-${counter}`,
        userId: ids.vendeur,
        locationId: magasinId,
        customerId: customer.id,
        totalHt: 100000,
        totalTax: 0,
        totalTtc: 100000,
        paidAmount: 0,
      },
    });
    return customer.id;
  };
  const debtOf = async (customerId: string) =>
    (await as(tokens.admin).get(`/api/customers/${customerId}`).expect(200))
      .body.balanceDue as number;
  const payByCheque = (
    customerId: string,
    n: string,
    token = tokens.vendeur,
    extra: object = {},
  ) =>
    as(token)
      .post('/api/payments/customer')
      .send({
        clientMutationId: randomUUID(),
        customerId,
        amount: 40000,
        cheque: cheque(n),
        ...extra,
      });
  const decide = (
    kind: 'customer' | 'supplier',
    id: string,
    status: 'ENCAISSE' | 'REJETE',
    key = randomUUID(),
    token = tokens.admin,
  ) =>
    as(token).post(`/api/cheques/${kind}/${id}/status`).send({
      clientMutationId: key,
      status,
      reason: 'Provision insuffisante',
    });

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
      const email = `e2e-chq-${key}-${suffix}@test.local`;
      const user = await createTestUser(prisma, {
        email,
        password: PASSWORD,
        roles: [role],
      });
      ids[key] = user.id;
      tokens[key] = (
        await request(server)
          .post('/api/auth/login')
          .send({ identifier: email, password: PASSWORD })
          .expect(200)
      ).body.accessToken;
    }
  });

  afterAll(async () => {
    const userIds = Object.values(ids);
    await prisma.notification.deleteMany({
      where: { userId: { in: userIds } },
    });
    await prisma.auditLog.deleteMany({ where: { userId: { in: userIds } } });
    for (const table of [prisma.customerPayment, prisma.supplierPayment]) {
      // Les contre-passations d'abord (elles référencent l'original).
      await (table as typeof prisma.customerPayment).deleteMany({
        where: { userId: { in: userIds }, reversesPaymentId: { not: null } },
      });
      await (table as typeof prisma.customerPayment).deleteMany({
        where: { userId: { in: userIds } },
      });
    }
    await prisma.sale.deleteMany({ where: { userId: { in: userIds } } });
    await prisma.customer.deleteMany({ where: { id: { in: customerIds } } });
    await prisma.supplier.deleteMany({ where: { id: { in: supplierIds } } });
    await prisma.user.deleteMany({ where: { id: { in: userIds } } });
    await e2e.app.close();
  });

  it('chèque client : sans caisse, dette réduite dès la remise, en portefeuille', async () => {
    const customerId = await indebted();
    // Le vendeur n'a AUCUNE caisse ouverte : un chèque n'en a pas besoin.
    const paid = await payByCheque(customerId, 'C-001').expect(201);
    expect(await debtOf(customerId)).toBe(60000);
    expect(
      await prisma.cashMovement.count({ where: { userId: ids.vendeur } }),
    ).toBe(0);
    const row = await prisma.customerPayment.findUniqueOrThrow({
      where: { id: paid.body.id },
    });
    expect(row).toMatchObject({
      method: 'CHEQUE',
      chequeNumber: 'C-001',
      chequeStatus: 'EN_PORTEFEUILLE',
    });
    const list = (
      await as(tokens.admin)
        .get('/api/cheques?status=EN_PORTEFEUILLE')
        .expect(200)
    ).body as { id: string; kind: string }[];
    expect(list).toContainEqual(
      expect.objectContaining({ id: paid.body.id, kind: 'CLIENT' }),
    );
    // Un chèque n'entre pas dans une caisse.
    await payByCheque(customerId, 'C-002', tokens.vendeur, {
      cashSessionId: randomUUID(),
    }).expect(422);
  });

  it('le vendeur saisit, seul l’admin statue', async () => {
    const customerId = await indebted();
    const paid = (await payByCheque(customerId, 'C-010').expect(201)).body;
    await as(tokens.vendeur).get('/api/cheques').expect(403);
    await decide(
      'customer',
      paid.id,
      'ENCAISSE',
      randomUUID(),
      tokens.vendeur,
    ).expect(403);
  });

  it('encaissé : rien ne bouge ; même décision renvoyée : même état ; autre : 409', async () => {
    const customerId = await indebted();
    const paid = (await payByCheque(customerId, 'C-020').expect(201)).body;
    const ok = await decide('customer', paid.id, 'ENCAISSE').expect(201);
    expect(ok.body).toMatchObject({ status: 'ENCAISSE', number: 'C-020' });
    await decide('customer', paid.id, 'ENCAISSE').expect(201);
    const late = await decide('customer', paid.id, 'REJETE').expect(409);
    expect(late.body.code).toBe('INVALID_STATE_TRANSITION');
    expect(await debtOf(customerId)).toBe(60000);
  });

  it('rejeté : la dette revient, une seule contre-passation, alerte au vendeur', async () => {
    const customerId = await indebted();
    const paid = (await payByCheque(customerId, 'C-030').expect(201)).body;
    const key = randomUUID();
    await decide('customer', paid.id, 'REJETE', key).expect(201);
    await decide('customer', paid.id, 'REJETE', key).expect(201);
    expect(await debtOf(customerId)).toBe(100000);
    expect(
      await prisma.customerPayment.count({
        where: { reversesPaymentId: paid.id },
      }),
    ).toBe(1);
    expect(
      await prisma.notification.count({
        where: { userId: ids.vendeur, type: 'CHEQUE_REJETE' },
      }),
    ).toBe(1);
    // Contre-passé : il ne se traite plus.
    await decide('customer', paid.id, 'ENCAISSE').expect(409);
  });

  it('contre-passation d’un chèque (erreur de saisie) : aucune caisse requise', async () => {
    const customerId = await indebted();
    const paid = (await payByCheque(customerId, 'C-040').expect(201)).body;
    // L'admin n'a pas de caisse ouverte : un chèque n'y a jamais été.
    await as(tokens.admin)
      .post(`/api/payments/customer/${paid.id}/reverse`)
      .send({ clientMutationId: randomUUID(), reason: 'Mauvais client' })
      .expect(201);
    expect(await debtOf(customerId)).toBe(100000);
    await decide('customer', paid.id, 'REJETE').expect(409);
  });

  it('chèque fournisseur : hors caisse, rejet → la dette revient', async () => {
    const supplier = await prisma.supplier.create({
      data: { name: `Fournisseur chèque ${suffix}`, openingBalance: 500000 },
    });
    supplierIds.push(supplier.id);
    const debt = async () =>
      (await as(tokens.admin).get(`/api/suppliers/${supplier.id}`).expect(200))
        .body.balanceDue as number;
    const pay = (fromCash: boolean) =>
      as(tokens.admin)
        .post('/api/payments/supplier')
        .send({
          clientMutationId: randomUUID(),
          supplierId: supplier.id,
          amount: 200000,
          fromCash,
          cheque: cheque('F-001'),
        });
    // Refusé pour ce qu'il est (un chèque hors caisse), pas faute de caisse.
    expect((await pay(true).expect(422)).body.code).toBe('VALIDATION_FAILED');
    const paid = (await pay(false).expect(201)).body;
    expect(await debt()).toBe(300000);
    await decide('supplier', paid.id, 'REJETE').expect(201);
    expect(await debt()).toBe(500000);
    const list = (await as(tokens.admin).get('/api/cheques?status=REJETE'))
      .body as { id: string; kind: string }[];
    expect(list).toContainEqual(
      expect.objectContaining({ id: paid.id, kind: 'FOURNISSEUR' }),
    );
  });

  /// Audits 21n : chèque fantôme, chèque encaissé, méthode sans chèque, liste.
  it('audits : tableau refusé, encaissé non contre-passable, « Tous » sans les annulés', async () => {
    const customerId = await indebted();
    await as(tokens.vendeur)
      .post('/api/payments/customer')
      .send({
        clientMutationId: randomUUID(),
        customerId,
        amount: 100,
        cheque: [],
      })
      .expect(400);
    const cashed = (await payByCheque(customerId, 'C-050').expect(201)).body;
    await decide('customer', cashed.id, 'ENCAISSE').expect(201);
    await as(tokens.admin)
      .post(`/api/payments/customer/${cashed.id}/reverse`)
      .send({ clientMutationId: randomUUID(), reason: 'Erreur' })
      .expect(409);
    const cancelled = (await payByCheque(customerId, 'C-051').expect(201)).body;
    await as(tokens.admin)
      .post(`/api/payments/customer/${cancelled.id}/reverse`)
      .send({ clientMutationId: randomUUID(), reason: 'Mauvais client' })
      .expect(201);
    const all = (await as(tokens.admin).get('/api/cheques').expect(200))
      .body as { id: string }[];
    expect(all.map((c) => c.id)).toContain(cashed.id);
    expect(all.map((c) => c.id)).not.toContain(cancelled.id);

    const supplier = await prisma.supplier.create({
      data: { name: `Fournisseur méthode ${suffix}`, openingBalance: 100000 },
    });
    supplierIds.push(supplier.id);
    const res = await as(tokens.admin)
      .post('/api/payments/supplier')
      .send({
        clientMutationId: randomUUID(),
        supplierId: supplier.id,
        amount: 1000,
        fromCash: false,
        method: 'CHEQUE',
      })
      .expect(422);
    expect(res.body.code).toBe('VALIDATION_FAILED');
  });

  it('un règlement en espèces n’est pas un chèque : 404', async () => {
    await decide('customer', randomUUID(), 'ENCAISSE').expect(404);
  });
});
