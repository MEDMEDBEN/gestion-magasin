import { randomUUID } from 'crypto';
import * as request from 'supertest';
import { RoleCode } from '../src/common/auth.decorators';
import { PrismaService } from '../src/prisma/prisma.service';
import { createE2eApp, createTestUser, E2eApp } from './helpers/e2e-app';

/// Chèques RETIRÉS le 2026-10-05 (sandbox/cheques), données GARDÉES en base.
/// Audits du 2026-10-05 : un ancien règlement par chèque ne doit jamais faire
/// bouger une caisse (il n'y est jamais entré) ni faire revenir une dette payée
/// en banque ; un chèque non encaissé ne se rend pas en espèces.
describe('Anciens chèques après le retrait (e2e)', () => {
  let e2e: E2eApp;
  let prisma: PrismaService;
  let server: E2eApp['server'];

  const suffix = Date.now();
  const PASSWORD = 'MotDePasseTemp1!';
  let adminId: string;
  let token: string;
  let customerId: string;
  let supplierId: string;
  let magasinId: string;

  const as = () => ({
    post: (url: string) =>
      request(server).post(url).set('Authorization', `Bearer ${token}`),
  });

  beforeAll(async () => {
    e2e = await createE2eApp();
    prisma = e2e.prisma;
    server = e2e.server;
    magasinId = (
      await prisma.location.findFirstOrThrow({ where: { type: 'MAGASIN' } })
    ).id;
    const email = `e2e-legacy-cheque-${suffix}@test.local`;
    adminId = (
      await createTestUser(prisma, {
        email,
        password: PASSWORD,
        roles: [RoleCode.ADMIN],
      })
    ).id;
    token = (
      await request(server)
        .post('/api/auth/login')
        .send({ identifier: email, password: PASSWORD })
        .expect(200)
    ).body.accessToken;
    customerId = (
      await prisma.customer.create({
        data: { name: `Client chèque ${suffix}`, creditLimit: 10_000_000 },
      })
    ).id;
    supplierId = (
      await prisma.supplier.create({
        data: { name: `Fourn. chèque ${suffix}` },
      })
    ).id;
  });

  afterAll(async () => {
    await prisma.auditLog.deleteMany({ where: { userId: adminId } });
    await prisma.cashMovement.deleteMany({ where: { userId: adminId } });
    await prisma.cashSession.deleteMany({ where: { userId: adminId } });
    await prisma.saleReturn.deleteMany({ where: { userId: adminId } });
    await prisma.customerPayment.deleteMany({ where: { customerId } });
    await prisma.supplierPayment.deleteMany({ where: { supplierId } });
    await prisma.sale.deleteMany({ where: { userId: adminId } });
    await prisma.customer.deleteMany({ where: { id: customerId } });
    await prisma.supplier.deleteMany({ where: { id: supplierId } });
    await prisma.user.deleteMany({ where: { id: adminId } });
    await e2e.app.close();
  });

  it('règlement client par chèque : contre-passation refusée, caisse intacte', async () => {
    const cheque = await prisma.customerPayment.create({
      data: {
        clientMutationId: randomUUID(),
        customerId,
        userId: adminId,
        amount: 50000,
        method: 'CHEQUE',
        chequeNumber: 'CH-1',
        chequeStatus: 'ENCAISSE',
      },
    });
    const movementsBefore = await prisma.cashMovement.count();

    const res = await as()
      .post(`/api/payments/customer/${cheque.id}/reverse`)
      .send({ clientMutationId: randomUUID(), reason: 'Erreur' })
      .expect(409);
    expect(res.body.code).toBe('INVALID_STATE_TRANSITION');
    expect(await prisma.cashMovement.count()).toBe(movementsBefore);
    expect(
      await prisma.customerPayment.count({
        where: { reversesPaymentId: cheque.id },
      }),
    ).toBe(0);
  });

  it('paiement fournisseur par chèque : contre-passation refusée', async () => {
    const cheque = await prisma.supplierPayment.create({
      data: {
        clientMutationId: randomUUID(),
        supplierId,
        userId: adminId,
        amount: 80000,
        method: 'CHEQUE',
        chequeNumber: 'CH-2',
        chequeStatus: 'EN_PORTEFEUILLE',
      },
    });
    const res = await as()
      .post(`/api/payments/supplier/${cheque.id}/reverse`)
      .send({ clientMutationId: randomUUID(), reason: 'Erreur' })
      .expect(409);
    expect(res.body.code).toBe('INVALID_STATE_TRANSITION');
  });

  it('retour sur une vente payée par chèque non encaissé : pas d’espèces', async () => {
    const product = await prisma.product.create({
      data: {
        sku: `E2E-LEGCH-${suffix}`,
        barcode: `E2E-LEGCH-BC-${suffix}`,
        name: 'Produit chèque',
      },
    });
    try {
      const sale = await prisma.sale.create({
        data: {
          number: `E2E-LEGCH-${suffix}`,
          userId: adminId,
          locationId: magasinId,
          customerId,
          totalHt: 100000,
          totalTax: 0,
          totalTtc: 100000,
          paidAmount: 0,
          lines: {
            create: {
              productId: product.id,
              quantity: '1',
              unitPriceHt: 100000,
              lineTotalHt: 100000,
              lineTaxAmount: 0,
              lineTotalTtc: 100000,
            },
          },
        },
        include: { lines: true },
      });
      await prisma.customerPayment.create({
        data: {
          clientMutationId: randomUUID(),
          customerId,
          saleId: sale.id,
          userId: adminId,
          amount: 100000,
          method: 'CHEQUE',
          chequeNumber: 'CH-3',
          chequeStatus: 'EN_PORTEFEUILLE',
        },
      });
      await as()
        .post('/api/cash-sessions')
        .send({ locationId: magasinId, openingFloat: 0 })
        .expect(201);

      const res = await as()
        .post(`/api/sales/${sale.id}/returns`)
        .send({
          id: randomUUID(),
          clientMutationId: randomUUID(),
          reason: 'Défectueux',
          refundMethod: 'ESPECES',
          lines: [{ saleLineId: sale.lines[0].id, quantity: '1' }],
        })
        .expect(422);
      expect(res.body.message).toContain('espèces');
    } finally {
      await prisma.saleReturn.deleteMany({ where: { userId: adminId } });
      await prisma.customerPayment.deleteMany({ where: { customerId } });
      await prisma.sale.deleteMany({ where: { userId: adminId } });
      await prisma.stockMovement.deleteMany({
        where: { productId: product.id },
      });
      await prisma.stock.deleteMany({ where: { productId: product.id } });
      await prisma.product.delete({ where: { id: product.id } });
    }
  });
});
