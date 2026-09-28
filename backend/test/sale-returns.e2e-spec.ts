import { randomUUID } from 'crypto';
import * as request from 'supertest';
import { RoleCode } from '../src/common/auth.decorators';
import { amountText } from '../src/common/pdf/pdf';
import { PrismaService } from '../src/prisma/prisma.service';
import { createE2eApp, createTestUser, E2eApp } from './helpers/e2e-app';

const DUE_DATE = '2099-12-31';

/// Retours client et factures d'avoir (P1 bis n°21l).
///
/// Éprouvé : stock rendu par le journal (règle 2), tout dans une transaction
/// (règle 3) ; espèces rendues depuis la caisse, jamais plus que payé ;
/// dette réduite par un avoir qui ne se contre-passe pas ; vente facturée →
/// avoir AV numéroté par le serveur (règle 11) ; quantités bornées, dernier
/// retour = reste exact ; rejouable sans double effet ; ADMIN seul.
describe('Retours client (e2e)', () => {
  let e2e: E2eApp;
  let prisma: PrismaService;
  let server: E2eApp['server'];

  const suffix = String(Date.now()).slice(-6);
  const PASSWORD = 'MotDePasseTemp1!';
  const userIds: string[] = [];
  const productIds: string[] = [];
  const customerIds: string[] = [];
  const tokens: Record<string, string> = {};
  let magasinId = '';
  let detailId = '';
  let tva19Id = '';
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
        sku: `E2E-RET-${suffix}-${n}`,
        barcode: `E2E-RET-BC-${suffix}-${n}`,
        name: `Produit retour ${n}`,
        taxRateId: tva19Id,
        lastPurchasePriceHt: 100000,
        prices: { create: [{ priceTierId: detailId, priceHt: 145000 }] },
      },
    });
    productIds.push(created.id);
    await prisma.stock.create({
      data: { productId: created.id, locationId: magasinId, quantity: '10' },
    });
    return created.id;
  };
  const stockOf = async (productId: string) =>
    (
      await prisma.stock.findUniqueOrThrow({
        where: { productId_locationId: { productId, locationId: magasinId } },
      })
    ).quantity.toFixed(3);

  /// Vente de 3 × 1 450 HT (TVA 19 %) : payée comptant, ou à crédit.
  /// `unitPriceHt` : prix modifié (au-dessus du coût), pour des montants qui
  /// ne se divisent pas juste.
  const sell = async (credit = false, unitPriceHt?: number) => {
    const p = await product();
    let customerId: string | undefined;
    if (credit) {
      customerId = (
        await prisma.customer.create({
          data: {
            name: `Client RET ${suffix}-${++counter}`,
            creditLimit: 10_000_000,
          },
        })
      ).id;
      customerIds.push(customerId);
    }
    const sale = (
      await as(tokens.admin)
        .post('/api/sales')
        .send({
          customerId,
          lines: [
            {
              productId: p,
              quantity: '3',
              ...(unitPriceHt && { unitPriceHt, priceEdited: true }),
            },
          ],
          paidAmount: credit ? 0 : 517650,
          ...(credit && { dueDate: DUE_DATE }),
        })
        .expect(201)
    ).body as { id: string; lines: { id: string }[]; totalTtc: number };
    return { sale, productId: p, lineId: sale.lines[0].id, customerId };
  };
  const giveBack = (
    saleId: string,
    lineId: string,
    quantity: string,
    refundMethod: 'ESPECES' | 'DETTE',
    extra: Record<string, unknown> = {},
  ) =>
    as(tokens.admin)
      .post(`/api/sales/${saleId}/returns`)
      .send({
        id: randomUUID(),
        lines: [{ saleLineId: lineId, quantity }],
        refundMethod,
        reason: 'Article défectueux',
        ...extra,
      });

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
    await prisma.storeSettings.upsert({
      where: { id: 1 },
      create: { id: 1, nif: '000016001234567', rc: '16/00-1234567B20' },
      update: { nif: '000016001234567', rc: '16/00-1234567B20' },
    });
    for (const [key, role] of [
      ['admin', RoleCode.ADMIN],
      ['vendeur', RoleCode.VENDEUR],
    ] as const) {
      const email = `e2e-ret-${key}-${suffix}@test.local`;
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
    // Caisse de l'admin : les ventes comptant et les remboursements y passent.
    await as(tokens.admin)
      .post('/api/cash-sessions')
      .send({ locationId: magasinId, openingFloat: 1_000_000 })
      .expect(201);
  });

  afterAll(async () => {
    await prisma.storeSettings.deleteMany();
    const sales = await prisma.sale.findMany({
      where: { userId: { in: userIds } },
      select: { id: true },
    });
    const saleIds = sales.map((s) => s.id);
    await prisma.customerPayment.deleteMany({
      where: { saleId: { in: saleIds } },
    });
    await prisma.saleReturn.deleteMany({ where: { saleId: { in: saleIds } } });
    await prisma.cashMovement.deleteMany({
      where: { userId: { in: userIds } },
    });
    await prisma.stockMovement.deleteMany({
      where: { productId: { in: productIds } },
    });
    await prisma.saleLine.deleteMany({ where: { saleId: { in: saleIds } } });
    await prisma.sale.deleteMany({ where: { id: { in: saleIds } } });
    await prisma.cashSession.deleteMany({ where: { userId: { in: userIds } } });
    await prisma.stock.deleteMany({ where: { productId: { in: productIds } } });
    await prisma.productPrice.deleteMany({
      where: { productId: { in: productIds } },
    });
    await prisma.product.deleteMany({ where: { id: { in: productIds } } });
    await prisma.customer.deleteMany({ where: { id: { in: customerIds } } });
    await prisma.auditLog.deleteMany({ where: { userId: { in: userIds } } });
    await prisma.user.deleteMany({ where: { id: { in: userIds } } });
    await e2e.app.close();
  });

  it('espèces : stock rendu, caisse rendue, numéro RC, jamais plus que vendu', async () => {
    const { sale, productId, lineId } = await sell();
    expect(await stockOf(productId)).toBe('7.000');
    const drawer = async () =>
      (await as(tokens.admin).get('/api/cash-sessions/current').expect(200))
        .body.currentAmount as number;
    const before = await drawer();

    const res = await giveBack(sale.id, lineId, '1', 'ESPECES').expect(201);
    expect(res.body.number).toMatch(/^RC-\d{4}-\d{5}$/);
    expect(res.body.creditNoteNumber).toBeNull();
    // 1/3 de 4 350 HT = 1 450 HT, TVA 275,50 → 1 725,50 TTC.
    expect(res.body).toMatchObject({ totalHt: 145000, totalTtc: 172550 });
    expect(await stockOf(productId)).toBe('8.000');
    expect(await drawer()).toBe(before - 172550);

    // Plus que ce qui reste (2) : refusé, rien ne bouge.
    await giveBack(sale.id, lineId, '2.5', 'ESPECES').expect(422);
    // Le dernier retour prend le RESTE exact : 3 lignes = total de la vente.
    const last = await giveBack(sale.id, lineId, '2', 'ESPECES').expect(201);
    expect(res.body.totalTtc + last.body.totalTtc).toBe(sale.totalTtc);
    expect(await stockOf(productId)).toBe('10.000');
    // Plus rien à rendre.
    await giveBack(sale.id, lineId, '0.5', 'ESPECES').expect(422);
    // Et la vente ne s'annule plus (elle doublerait les retours).
    await as(tokens.admin).post(`/api/sales/${sale.id}/cancel`).expect(409);
  });

  it('rejeu de la même clé : un seul retour ; autre contenu : 409', async () => {
    const { sale, productId, lineId } = await sell();
    const key = randomUUID();
    const body = { clientMutationId: key };
    const first = await giveBack(sale.id, lineId, '1', 'ESPECES', body).expect(
      201,
    );
    const again = await giveBack(sale.id, lineId, '1', 'ESPECES', body).expect(
      201,
    );
    expect(again.body.id).toBe(first.body.id);
    expect(await stockOf(productId)).toBe('8.000');
    await giveBack(sale.id, lineId, '2', 'ESPECES', body).expect(409);
  });

  it('dette : l’avoir réduit le reste dû ; espèces refusées sur une vente impayée', async () => {
    const { sale, lineId, customerId } = await sell(true);
    // Rien n'a été payé : pas d'espèces à rendre.
    await giveBack(sale.id, lineId, '1', 'ESPECES').expect(422);

    const ret = await giveBack(sale.id, lineId, '1', 'DETTE').expect(201);
    const sheet = (
      await as(tokens.admin).get(`/api/customers/${customerId}`).expect(200)
    ).body;
    expect(sheet.balanceDue).toBe(sale.totalTtc - ret.body.totalTtc);
    const detail = (
      await as(tokens.admin).get(`/api/sales/${sale.id}`).expect(200)
    ).body;
    expect(detail.remainingAmount).toBe(sale.totalTtc - ret.body.totalTtc);

    // L'avoir apparaît aux règlements, et ne se contre-passe pas.
    const avoir = await prisma.customerPayment.findFirstOrThrow({
      where: { saleReturnId: ret.body.id },
    });
    expect(avoir.note).toContain(ret.body.number);
    await as(tokens.admin)
      .post(`/api/payments/customer/${avoir.id}/reverse`)
      .send({ reason: 'Tentative' })
      .expect(409);
  });

  it('vente facturée : facture d’avoir AV numérotée, PDF imprimable', async () => {
    const { sale, lineId } = await sell();
    await as(tokens.admin).post(`/api/sales/${sale.id}/invoice`).expect(200);
    const ret = await giveBack(sale.id, lineId, '1', 'ESPECES').expect(201);
    expect(ret.body.creditNoteNumber).toMatch(/^AV-\d{4}-\d{6}$/);
    const pdf = await as(tokens.admin)
      .get(`/api/sales/returns/${ret.body.id}/pdf`)
      .expect(200);
    expect(pdf.headers['content-disposition']).toContain(
      `${ret.body.creditNoteNumber}.pdf`,
    );
    const audit = await prisma.auditLog.findFirstOrThrow({
      where: { entityType: 'SaleReturn', entityId: ret.body.id },
    });
    expect(audit.newValue).toMatchObject({
      creditNoteNumber: ret.body.creditNoteNumber,
    });
  });

  it('ADMIN seul ; motif obligatoire ; ligne étrangère refusée', async () => {
    const { sale, lineId } = await sell();
    await as(tokens.vendeur)
      .post(`/api/sales/${sale.id}/returns`)
      .send({
        id: randomUUID(),
        lines: [{ saleLineId: lineId, quantity: '1' }],
        refundMethod: 'ESPECES',
        reason: 'Essai',
      })
      .expect(403);
    await giveBack(sale.id, lineId, '1', 'ESPECES', { reason: '  ' }).expect(
      400,
    );
    const other = await sell();
    await giveBack(sale.id, other.lineId, '1', 'ESPECES').expect(422);
  });

  /// Audit 21l : un montant qui ne se divise pas juste — trois retours d'une
  /// unité rendent EXACTEMENT la vente (arrondi cumulé), HT comme TVA.
  it('retours successifs sur un montant indivisible : total exact', async () => {
    const { sale, lineId } = await sell(true, 145001);
    const parts = [];
    for (let i = 0; i < 3; i++) {
      parts.push(
        (await giveBack(sale.id, lineId, '1', 'DETTE').expect(201)).body,
      );
    }
    const detail = (
      await as(tokens.admin).get(`/api/sales/${sale.id}`).expect(200)
    ).body;
    expect(parts.reduce((s, p) => s + p.totalHt, 0)).toBe(detail.totalHt);
    expect(parts.reduce((s, p) => s + p.totalTtc, 0)).toBe(sale.totalTtc);
    expect(detail.remainingAmount).toBe(0);
  });

  /// Audit 21l : un ticket dont des articles sont revenus n'a pas d'avoir ;
  /// le facturer ensuite déclarerait une TVA sur de la marchandise rendue.
  it('ticket avec retour : ne se facture plus', async () => {
    const { sale, lineId } = await sell();
    await giveBack(sale.id, lineId, '1', 'ESPECES').expect(201);
    const res = await as(tokens.admin)
      .post(`/api/sales/${sale.id}/invoice`)
      .expect(409);
    expect(res.body.code).toBe('INVALID_STATE_TRANSITION');
  });

  /// Audit 21l : règlement de 100 %, tout remboursé en espèces, puis
  /// contre-passation du règlement → les espèces sortiraient deux fois.
  it('règlement dont la vente a été remboursée : ne se contre-passe plus', async () => {
    const { sale, lineId, customerId } = await sell(true);
    const payment = (
      await as(tokens.admin)
        .post('/api/payments/customer')
        .send({ customerId, saleId: sale.id, amount: sale.totalTtc })
        .expect(201)
    ).body;
    await giveBack(sale.id, lineId, '3', 'ESPECES').expect(201);
    await as(tokens.admin)
      .post(`/api/payments/customer/${payment.id}/reverse`)
      .send({ reason: 'Erreur de saisie' })
      .expect(409);
    // Sans remboursement, la contre-passation reste possible.
    const other = await sell(true);
    const ok = (
      await as(tokens.admin)
        .post('/api/payments/customer')
        .send({
          customerId: other.customerId,
          saleId: other.sale.id,
          amount: other.sale.totalTtc,
        })
        .expect(201)
    ).body;
    await as(tokens.admin)
      .post(`/api/payments/customer/${ok.id}/reverse`)
      .send({ reason: 'Erreur de saisie' })
      .expect(201);
  });

  /// P1 bis n°21n : le relevé de compte finit sur la dette affichée — ventes,
  /// règlement, avoir, contre-passation compris. ADMIN seul.
  it('relevé de compte client : dernier solde = dette ; ADMIN seul', async () => {
    const { sale, lineId, customerId } = await sell(true);
    const paid = (
      await as(tokens.admin)
        .post('/api/payments/customer')
        .send({ customerId, saleId: sale.id, amount: 100000 })
        .expect(201)
    ).body;
    await giveBack(sale.id, lineId, '1', 'DETTE').expect(201);
    await as(tokens.admin)
      .post(`/api/payments/customer/${paid.id}/reverse`)
      .send({ reason: 'Erreur de saisie' })
      .expect(201);
    const debt = (
      await as(tokens.admin).get(`/api/customers/${customerId}`).expect(200)
    ).body.balanceDue as number;

    const csv = (
      await as(tokens.admin)
        .get(`/api/customers/${customerId}/statement?format=csv`)
        .buffer(true)
        .parse((r, done) => {
          const chunks: Buffer[] = [];
          r.on('data', (c: Buffer) => chunks.push(c));
          r.on('end', () => done(null, Buffer.concat(chunks)));
        })
        .expect(200)
    ).body as Buffer;
    const rows = csv.toString('utf-8').trim().split(/\r?\n/);
    // Vente, règlement, avoir, contre-passation.
    expect(rows.filter((l) => /\d{2}\/\d{2}\/\d{4}/.test(l))).toHaveLength(4);
    expect(rows[rows.length - 1].trim().split(';').pop()).toBe(
      amountText(debt),
    );
    await as(tokens.admin)
      .get(`/api/customers/${customerId}/statement?format=pdf`)
      .expect(200)
      .expect('content-type', 'application/pdf');
    await as(tokens.vendeur)
      .get(`/api/customers/${customerId}/statement?format=pdf`)
      .expect(403);
  });

  /// Audit 21n : jamais d'espèces rendues contre un chèque pas encore encaissé.
  it('chèque en portefeuille : pas de remboursement en espèces avant encaissement', async () => {
    const { sale, lineId, customerId } = await sell(true);
    const paid = (
      await as(tokens.admin)
        .post('/api/payments/customer')
        .send({
          customerId,
          saleId: sale.id,
          amount: sale.totalTtc,
          cheque: { number: 'R-1', bank: 'BNA' },
        })
        .expect(201)
    ).body;
    await giveBack(sale.id, lineId, '1', 'ESPECES').expect(422);
    await as(tokens.admin)
      .post(`/api/cheques/customer/${paid.id}/status`)
      .send({ clientMutationId: randomUUID(), status: 'ENCAISSE' })
      .expect(201);
    await giveBack(sale.id, lineId, '1', 'ESPECES').expect(201);
  });

  /// CA NET des retours : le rapport d'activité et l'accueil déduisent ce qui
  /// est rendu (sinon le CA serait gonflé de marchandise revenue).
  it('rapport d’activité et accueil : CA net des retours du jour', async () => {
    const day = new Intl.DateTimeFormat('en-CA', {
      timeZone: 'Africa/Algiers',
    }).format(new Date());
    const report = async () =>
      (
        await as(tokens.admin)
          .get(`/api/reports/sales?from=${day}&to=${day}`)
          .expect(200)
      ).body.totals as { revenueHt: number; returnsHt: number };
    const dashboard = async () =>
      (await as(tokens.admin).get('/api/dashboard').expect(200)).body;
    const before = await report();
    const ca = JSON.stringify(await dashboard());
    const { sale, lineId } = await sell();
    const ret = await giveBack(sale.id, lineId, '1', 'ESPECES').expect(201);
    const after = await report();
    // + vente 4 350 HT − retour 1 450 HT.
    expect(after.revenueHt - before.revenueHt).toBe(435000 - ret.body.totalHt);
    expect(after.returnsHt - before.returnsHt).toBe(ret.body.totalHt);
    expect(JSON.stringify(await dashboard())).not.toBe(ca);
  });
});
