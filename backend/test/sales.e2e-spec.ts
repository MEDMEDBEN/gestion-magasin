import { randomUUID } from 'crypto';
import * as request from 'supertest';
import { RoleCode } from '../src/common/auth.decorators';
import { PrismaService } from '../src/prisma/prisma.service';
import { createE2eApp, createTestUser, E2eApp } from './helpers/e2e-app';

/// Ventes (P0 n°4) — priorité absolue des tests : argent + stock + droits.
/// Règles 2, 3, 4, 9, 11, 12, 13 de CLAUDE.md.
describe('Ventes (e2e)', () => {
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
  let detailId = '';
  let grosId = '';
  let tva19Id = '';
  let counter = 0;

  const as = (token: string) => ({
    get: (url: string) =>
      request(server).get(url).set('Authorization', `Bearer ${token}`),
    post: (url: string) =>
      request(server).post(url).set('Authorization', `Bearer ${token}`),
  });

  /// Produit au magasin : prix DETAIL / GROS en centimes, TVA 19 %.
  const product = async (stock: string, detail = 145000, gros = 120000) => {
    const n = ++counter;
    const created = await prisma.product.create({
      data: {
        sku: `E2E-SALE-${suffix}-${n}`,
        barcode: `E2E-SALE-BC-${suffix}-${n}`,
        name: `Produit vente ${n}`,
        taxRateId: tva19Id,
        prices: {
          create: [
            { priceTierId: detailId, priceHt: detail },
            { priceTierId: grosId, priceHt: gros },
          ],
        },
      },
    });
    productIds.push(created.id);
    await prisma.stock.create({
      data: { productId: created.id, locationId: magasinId, quantity: stock },
    });
    return created.id;
  };

  const customer = async (creditLimit: number, tier?: string) => {
    const created = await prisma.customer.create({
      data: { name: `Client e2e ${++counter}`, creditLimit, priceTierId: tier },
    });
    customerIds.push(created.id);
    return created.id;
  };

  const stockOf = async (productId: string) =>
    (
      await prisma.stock.findUniqueOrThrow({
        where: { productId_locationId: { productId, locationId: magasinId } },
      })
    ).quantity.toFixed(3);

  const openCash = (token: string) =>
    as(token)
      .post('/api/cash-sessions')
      .send({ locationId: magasinId, openingFloat: 0 });

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
    grosId = (
      await prisma.priceTier.findUniqueOrThrow({ where: { code: 'GROS' } })
    ).id;
    tva19Id = (await prisma.taxRate.findFirstOrThrow({ where: { rate: 19 } }))
      .id;
    for (const [key, role] of [
      ['admin', RoleCode.ADMIN],
      ['vendeur', RoleCode.VENDEUR],
      ['vendeurSansCaisse', RoleCode.VENDEUR],
      ['autreVendeur', RoleCode.VENDEUR],
      ['magasinier', RoleCode.MAGASINIER],
    ] as const) {
      const email = `e2e-sale-${key}-${suffix}@test.local`;
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
    await openCash(tokens.vendeur).expect(201);
    await openCash(tokens.admin).expect(201);
    await openCash(tokens.autreVendeur).expect(201);
  });

  afterAll(async () => {
    const sales = await prisma.sale.findMany({
      where: { userId: { in: userIds } },
      select: { id: true },
    });
    const saleIds = sales.map((s) => s.id);
    await prisma.auditLog.deleteMany({
      where: {
        OR: [{ entityId: { in: saleIds } }, { userId: { in: userIds } }],
      },
    });
    await prisma.cashMovement.deleteMany({
      where: { userId: { in: userIds } },
    });
    await prisma.customerPayment.deleteMany({
      where: { customerId: { in: customerIds } },
    });
    await prisma.sale.deleteMany({ where: { id: { in: saleIds } } });
    await prisma.cashSession.deleteMany({ where: { userId: { in: userIds } } });
    await prisma.stockMovement.deleteMany({
      where: { productId: { in: productIds } },
    });
    await prisma.stock.deleteMany({ where: { productId: { in: productIds } } });
    await prisma.product.deleteMany({ where: { id: { in: productIds } } });
    await prisma.customer.deleteMany({ where: { id: { in: customerIds } } });
    await prisma.user.deleteMany({ where: { id: { in: userIds } } });
    await e2e.app.close();
  });

  describe('validation d’une vente', () => {
    it('comptoir payé en espèces : prix du tarif par défaut figé, TVA, stock, caisse', async () => {
      const p = await product('10.000');
      // 2,5 × 1 450,00 = 3 625,00 HT ; TVA 19 % = 688,75 ; TTC 4 313,75
      const res = await as(tokens.vendeur)
        .post('/api/sales')
        .send({
          lines: [{ productId: p, quantity: '2.5' }],
          paidAmount: 431375,
        })
        .expect(201);

      expect(res.body).toMatchObject({
        type: 'TICKET',
        status: 'VALIDEE',
        totalHt: 362500,
        totalTax: 68875,
        totalTtc: 431375,
        paidAmount: 431375,
        remainingAmount: 0,
      });
      expect(res.body.number).toMatch(/^TK-\d{4}-\d{6}$/);
      expect(res.body.lines[0]).toMatchObject({
        unitPriceHt: 145000,
        priceTierId: detailId,
        taxRate: '19.00',
        quantity: '2.500',
      });
      expect(await stockOf(p)).toBe('7.500');

      const movement = await prisma.stockMovement.findFirstOrThrow({
        where: { operationId: res.body.id },
      });
      expect(movement).toMatchObject({ type: 'VENTE', operationType: 'SALE' });
      const cash = await as(tokens.vendeur)
        .get('/api/cash-sessions/current')
        .expect(200);
      expect(cash.body.cashSalesAmount).toBeGreaterThanOrEqual(431375);

      // Le prix est FIGÉ : changer le tarif ensuite ne touche pas la vente passée.
      await prisma.productPrice.updateMany({
        where: { productId: p, priceTierId: detailId },
        data: { priceHt: 999999 },
      });
      const again = await as(tokens.vendeur)
        .get(`/api/sales/${res.body.id}`)
        .expect(200);
      expect(again.body.lines[0].unitPriceHt).toBe(145000);
    });

    it('client GROS : son tarif s’applique', async () => {
      const p = await product('10.000');
      const c = await customer(0, grosId);
      const res = await as(tokens.vendeur)
        .post('/api/sales')
        .send({
          customerId: c,
          lines: [{ productId: p, quantity: '1' }],
          paidAmount: 142800,
        })
        .expect(201);
      expect(res.body.lines[0]).toMatchObject({
        unitPriceHt: 120000,
        priceTierId: grosId,
      });
      expect(res.body.totalTtc).toBe(142800);
    });

    it('stock insuffisant → STOCK_NEGATIVE, et RIEN n’est écrit (atomicité)', async () => {
      const ok = await product('10.000');
      const short = await product('1.000');
      const before = await prisma.sale.count();

      const res = await as(tokens.vendeur)
        .post('/api/sales')
        .send({
          lines: [
            { productId: ok, quantity: '2' },
            { productId: short, quantity: '5' },
          ],
          // Payée en entier : la vente est ÉCRITE puis défaite par le refus de stock.
          paidAmount: 7 * 172550,
        })
        .expect(422);

      expect(res.body.code).toBe('STOCK_NEGATIVE');
      expect(await prisma.sale.count()).toBe(before);
      expect(await stockOf(ok)).toBe('10.000');
    });

    it('deux ventes simultanées de la DERNIÈRE unité : une seule passe', async () => {
      const p = await product('1.000');
      const results = await Promise.all(
        [tokens.vendeur, tokens.autreVendeur].map((token) =>
          as(token)
            .post('/api/sales')
            .send({
              lines: [{ productId: p, quantity: '1' }],
              paidAmount: 172550,
            }),
        ),
      );
      expect(results.map((r) => r.status).sort()).toEqual([201, 422]);
      expect(await stockOf(p)).toBe('0.000');
    });

    it('espèces sans caisse ouverte → CASH_SESSION_REQUIRED', async () => {
      const p = await product('10.000');
      const res = await as(tokens.vendeurSansCaisse)
        .post('/api/sales')
        .send({ lines: [{ productId: p, quantity: '1' }], paidAmount: 100 })
        .expect(422);
      expect(res.body.code).toBe('CASH_SESSION_REQUIRED');
    });

    it('prix non fixé pour le tarif → PRICE_NOT_DEFINED', async () => {
      const p = await product('10.000');
      await prisma.productPrice.deleteMany({ where: { productId: p } });
      const res = await as(tokens.vendeur)
        .post('/api/sales')
        .send({ lines: [{ productId: p, quantity: '1' }], paidAmount: 0 })
        .expect(422);
      expect(res.body.code).toBe('PRICE_NOT_DEFINED');
    });

    it('remise : refusée au VENDEUR, acceptée pour l’ADMIN', async () => {
      const p = await product('10.000');
      const line = { productId: p, quantity: '1', discountAmount: 10000 };
      const denied = await as(tokens.vendeur)
        .post('/api/sales')
        .send({ lines: [line], paidAmount: 0 })
        .expect(403);
      expect(denied.body.code).toBe('DISCOUNT_NOT_ALLOWED');

      // 1 450 − 100 = 1 350 HT ; TVA 256,50 ; TTC 1 606,50
      const ok = await as(tokens.admin)
        .post('/api/sales')
        .send({ lines: [line], paidAmount: 160650 })
        .expect(201);
      expect(ok.body).toMatchObject({
        totalHt: 135000,
        totalTax: 25650,
        totalTtc: 160650,
      });
    });

    it('total démesuré → 422 (jamais une 500)', async () => {
      const p = await product('99999999999.000', 2_000_000_000, 2_000_000_000);
      const res = await as(tokens.admin)
        .post('/api/sales')
        .send({ lines: [{ productId: p, quantity: '5' }], paidAmount: 0 })
        .expect(422);
      expect(res.body.code).toBe('VALIDATION_FAILED');
    });

    it('tarif du client désactivé : le tarif par défaut s’applique', async () => {
      const p = await product('10.000');
      const tier = await prisma.priceTier.create({
        data: {
          code: `E2E-OFF-${suffix}`,
          name: 'Tarif retiré',
          isActive: false,
        },
      });
      try {
        const c = await customer(0, tier.id);
        const res = await as(tokens.vendeur)
          .post('/api/sales')
          .send({
            customerId: c,
            lines: [{ productId: p, quantity: '1' }],
            paidAmount: 172550,
          })
          .expect(201);
        expect(res.body.lines[0]).toMatchObject({
          priceTierId: detailId,
          unitPriceHt: 145000,
        });
      } finally {
        await prisma.customer.updateMany({
          where: { priceTierId: tier.id },
          data: { priceTierId: null },
        });
        await prisma.saleLine.updateMany({
          where: { priceTierId: tier.id },
          data: { priceTierId: null },
        });
        await prisma.priceTier.delete({ where: { id: tier.id } });
      }
    });

    it('le client n’envoie JAMAIS le prix : un champ de prix est refusé', async () => {
      const p = await product('10.000');
      await as(tokens.vendeur)
        .post('/api/sales')
        .send({
          lines: [{ productId: p, quantity: '1', unitPriceHt: 1 }],
          paidAmount: 0,
        })
        .expect(400);
    });

    it('renvoi du même panier (même id) : UNE seule vente, stock sorti une fois', async () => {
      const p = await product('10.000');
      const id = randomUUID();
      const body = {
        id,
        lines: [{ productId: p, quantity: '1' }],
        paidAmount: 172550,
      };
      const first = await as(tokens.vendeur)
        .post('/api/sales')
        .send(body)
        .expect(201);
      const second = await as(tokens.vendeur)
        .post('/api/sales')
        .send(body)
        .expect(201);
      expect(second.body.number).toBe(first.body.number);
      expect(await stockOf(p)).toBe('9.000');
    });

    it('renvoi du même id avec un AUTRE panier → 409, rien de plus n’est sorti', async () => {
      const p = await product('10.000');
      const id = randomUUID();
      await as(tokens.vendeur)
        .post('/api/sales')
        .send({
          id,
          lines: [{ productId: p, quantity: '1' }],
          paidAmount: 172550,
        })
        .expect(201);
      const res = await as(tokens.vendeur)
        .post('/api/sales')
        .send({
          id,
          lines: [{ productId: p, quantity: '2' }],
          paidAmount: 345100,
        })
        .expect(409);
      expect(res.body.code).toBe('CONFLICT');
      expect(await stockOf(p)).toBe('9.000');
    });

    it('total annoncé par l’app ≠ total serveur (prix changé) → 409, rien n’est écrit', async () => {
      const p = await product('10.000');
      const res = await as(tokens.vendeur)
        .post('/api/sales')
        .send({
          lines: [{ productId: p, quantity: '1' }],
          paidAmount: 150000,
          expectedTotalTtc: 150000,
        })
        .expect(409);
      expect(res.body.code).toBe('CONFLICT');
      expect(await stockOf(p)).toBe('10.000');
      await as(tokens.vendeur)
        .post('/api/sales')
        .send({
          lines: [{ productId: p, quantity: '1' }],
          paidAmount: 172550,
          expectedTotalTtc: 172550,
        })
        .expect(201);
    });

    it('MAGASINIER ne vend pas ; encaissé > total → 422 ; quantité nulle → 422', async () => {
      const p = await product('10.000');
      await as(tokens.magasinier)
        .post('/api/sales')
        .send({ lines: [{ productId: p, quantity: '1' }], paidAmount: 0 })
        .expect(403);
      await as(tokens.vendeur)
        .post('/api/sales')
        .send({
          lines: [{ productId: p, quantity: '1' }],
          paidAmount: 99999999,
        })
        .expect(422);
      await as(tokens.vendeur)
        .post('/api/sales')
        .send({ lines: [{ productId: p, quantity: '0' }], paidAmount: 0 })
        .expect(422);
    });
  });

  describe('crédit client (plafond fixé par l’admin)', () => {
    it('dans le plafond : accepté, reste dû calculé ; au-delà : refusé', async () => {
      const p = await product('10.000');
      const c = await customer(200000); // 2 000,00 DA de plafond
      const credit = await as(tokens.vendeur)
        .post('/api/sales')
        .send({
          customerId: c,
          lines: [{ productId: p, quantity: '1' }],
          paidAmount: 0,
        })
        .expect(201);
      expect(credit.body.remainingAmount).toBe(172550);

      const over = await as(tokens.vendeur)
        .post('/api/sales')
        .send({
          customerId: c,
          lines: [{ productId: p, quantity: '1' }],
          paidAmount: 0,
        })
        .expect(422);
      expect(over.body.code).toBe('CREDIT_LIMIT_EXCEEDED');
    });

    it('plafond par défaut 0 : aucun crédit ; comptoir sans client : aucun crédit', async () => {
      const p = await product('10.000');
      const c = await customer(0);
      await as(tokens.vendeur)
        .post('/api/sales')
        .send({
          customerId: c,
          lines: [{ productId: p, quantity: '1' }],
          paidAmount: 100,
        })
        .expect(422);
      const anonymous = await as(tokens.vendeur)
        .post('/api/sales')
        .send({ lines: [{ productId: p, quantity: '1' }], paidAmount: 100 })
        .expect(422);
      expect(anonymous.body.code).toBe('CREDIT_LIMIT_EXCEEDED');
    });

    it('deux ventes à crédit simultanées ne dépassent pas le plafond ensemble', async () => {
      const p = await product('10.000');
      const c = await customer(200000);
      const results = await Promise.all(
        [tokens.vendeur, tokens.autreVendeur].map((token) =>
          as(token)
            .post('/api/sales')
            .send({
              customerId: c,
              lines: [{ productId: p, quantity: '1' }],
              paidAmount: 0,
            }),
        ),
      );
      expect(results.map((r) => r.status).sort()).toEqual([201, 422]);
    });
  });

  describe('facture (numéro légal sans trou)', () => {
    it('ticket → facture FA-AAAA-NNNNNN, séquentiel, idempotent, audité', async () => {
      const p = await product('10.000');
      const sale = async () =>
        (
          await as(tokens.vendeur)
            .post('/api/sales')
            .send({
              lines: [{ productId: p, quantity: '1' }],
              paidAmount: 172550,
            })
            .expect(201)
        ).body;
      const [a, b] = [await sale(), await sale()];

      const fa = await as(tokens.vendeur)
        .post(`/api/sales/${a.id}/invoice`)
        .expect(200);
      const fb = await as(tokens.vendeur)
        .post(`/api/sales/${b.id}/invoice`)
        .expect(200);
      expect(fa.body.invoiceNumber).toMatch(/^FA-\d{4}-\d{6}$/);
      expect(fa.body.type).toBe('FACTURE');
      const seq = (n: string) => Number(n.slice(-6));
      expect(seq(fb.body.invoiceNumber)).toBe(seq(fa.body.invoiceNumber) + 1);

      const again = await as(tokens.vendeur)
        .post(`/api/sales/${a.id}/invoice`)
        .expect(200);
      expect(again.body.invoiceNumber).toBe(fa.body.invoiceNumber);
      const audit = await prisma.auditLog.count({
        where: { entityType: 'Sale', entityId: a.id, action: 'VALIDATE' },
      });
      expect(audit).toBe(1);
    });

    it('facturations SIMULTANÉES : numéros tous différents et consécutifs', async () => {
      const p = await product('50.000');
      const sales = [];
      for (let i = 0; i < 5; i++) {
        sales.push(
          (
            await as(tokens.admin)
              .post('/api/sales')
              .send({
                lines: [{ productId: p, quantity: '1' }],
                paidAmount: 172550,
              })
              .expect(201)
          ).body,
        );
      }
      const invoiced = await Promise.all(
        sales.map((s) => as(tokens.admin).post(`/api/sales/${s.id}/invoice`)),
      );
      const numbers = invoiced
        .map((r) => Number(r.body.invoiceNumber.slice(-6)))
        .sort((x, y) => x - y);
      expect(new Set(numbers).size).toBe(5);
      expect(numbers[4] - numbers[0]).toBe(4);
    });

    it('un vendeur ne facture pas la vente d’un collègue', async () => {
      const p = await product('10.000');
      const sale = (
        await as(tokens.autreVendeur)
          .post('/api/sales')
          .send({
            lines: [{ productId: p, quantity: '1' }],
            paidAmount: 172550,
          })
          .expect(201)
      ).body;
      await as(tokens.vendeur)
        .post(`/api/sales/${sale.id}/invoice`)
        .expect(404);
      await as(tokens.vendeur).get(`/api/sales/${sale.id}`).expect(404);
    });
  });

  describe('annulation (ADMIN)', () => {
    it('retours en stock, sortie de caisse, statut ANNULEE, audit ; jamais deux fois', async () => {
      const p = await product('10.000');
      const sale = (
        await as(tokens.vendeur)
          .post('/api/sales')
          .send({
            lines: [{ productId: p, quantity: '3' }],
            paidAmount: 517650,
          })
          .expect(201)
      ).body;
      expect(await stockOf(p)).toBe('7.000');

      await as(tokens.vendeur).post(`/api/sales/${sale.id}/cancel`).expect(403);
      const cancelled = await as(tokens.admin)
        .post(`/api/sales/${sale.id}/cancel`)
        .expect(200);
      expect(cancelled.body).toMatchObject({
        status: 'ANNULEE',
        remainingAmount: 0,
      });
      expect(await stockOf(p)).toBe('10.000');
      const out = await prisma.cashMovement.findFirst({
        where: { saleId: sale.id, type: 'SORTIE' },
      });
      expect(out?.amount).toBe(517650);
      await as(tokens.admin).post(`/api/sales/${sale.id}/cancel`).expect(409);
      expect(
        await prisma.auditLog.count({
          where: { entityId: sale.id, action: 'CANCEL' },
        }),
      ).toBe(1);
    });

    it('une vente facturée ne s’annule pas', async () => {
      const p = await product('10.000');
      const sale = (
        await as(tokens.admin)
          .post('/api/sales')
          .send({
            lines: [{ productId: p, quantity: '1' }],
            paidAmount: 172550,
          })
          .expect(201)
      ).body;
      await as(tokens.admin).post(`/api/sales/${sale.id}/invoice`).expect(200);
      await as(tokens.admin).post(`/api/sales/${sale.id}/cancel`).expect(409);
    });
  });

  describe('annulation refusée (argent déjà bougé ailleurs)', () => {
    it('caisse de la vente déjà clôturée → 409', async () => {
      const p = await product('10.000');
      await openCash(tokens.vendeurSansCaisse).expect(201);
      const sale = (
        await as(tokens.vendeurSansCaisse)
          .post('/api/sales')
          .send({
            lines: [{ productId: p, quantity: '1' }],
            paidAmount: 172550,
          })
          .expect(201)
      ).body;
      await as(tokens.vendeurSansCaisse)
        .post(`/api/cash-sessions/${sale.cashSessionId}/close`)
        .send({ countedAmount: 172550 })
        .expect(200);
      await as(tokens.admin).post(`/api/sales/${sale.id}/cancel`).expect(409);
      expect(await stockOf(p)).toBe('9.000');
    });

    it('règlement rattaché à la vente → 409', async () => {
      const p = await product('10.000');
      const c = await customer(500000);
      const sale = (
        await as(tokens.vendeur)
          .post('/api/sales')
          .send({
            customerId: c,
            lines: [{ productId: p, quantity: '1' }],
            paidAmount: 0,
          })
          .expect(201)
      ).body;
      await as(tokens.vendeur)
        .post('/api/payments/customer')
        .send({ customerId: c, saleId: sale.id, amount: 10000 })
        .expect(201);
      await as(tokens.admin).post(`/api/sales/${sale.id}/cancel`).expect(409);
    });

    it('vente soldée par un acompte général : l’annuler rendrait la dette négative → 409', async () => {
      const p = await product('10.000');
      const c = await customer(500000);
      const sale = (
        await as(tokens.vendeur)
          .post('/api/sales')
          .send({
            customerId: c,
            lines: [{ productId: p, quantity: '1' }],
            paidAmount: 0,
          })
          .expect(201)
      ).body;
      await as(tokens.vendeur)
        .post('/api/payments/customer')
        .send({ customerId: c, amount: 172550 })
        .expect(201);
      await as(tokens.admin).post(`/api/sales/${sale.id}/cancel`).expect(409);
      expect(await stockOf(p)).toBe('9.000');
    });
  });

  it('liste : le vendeur voit ses ventes, l’admin toutes', async () => {
    const mine = await as(tokens.autreVendeur)
      .get('/api/sales?limit=200')
      .expect(200);
    expect(
      mine.body.data.every((s: { userId: string }) => s.userId === userIds[3]),
    ).toBe(true);
    const all = await as(tokens.admin).get('/api/sales?limit=200').expect(200);
    expect(all.body.meta.total).toBeGreaterThanOrEqual(mine.body.meta.total);
  });
});
