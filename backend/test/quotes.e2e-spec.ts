import { randomUUID } from 'crypto';
import * as request from 'supertest';
import { RoleCode } from '../src/common/auth.decorators';
import { localDate } from '../src/common/document-number';
import { PrismaService } from '../src/prisma/prisma.service';
import { createE2eApp, createTestUser, E2eApp } from './helpers/e2e-app';

/// Devis (P1 n°21a, spec §8quater).
///
/// Éprouvé en priorité : un devis ne touche JAMAIS le stock ; il suit les
/// MÊMES règles de prix que la vente ; sa conversion est une vente complète,
/// atomique (tout ou rien) et idempotente ; un devis expiré ne se convertit pas.
describe('Devis (e2e)', () => {
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

  /// Produit au magasin : DETAIL / GROS en centimes, TVA 19 %, coût 1 000,00.
  const product = async (stock: string, detail = 145000, gros = 120000) => {
    const n = ++counter;
    const created = await prisma.product.create({
      data: {
        sku: `E2E-QUOTE-${suffix}-${n}`,
        barcode: `E2E-QUOTE-BC-${suffix}-${n}`,
        name: `Produit devis ${n}`,
        taxRateId: tva19Id,
        lastPurchasePriceHt: 100000,
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

  const customer = async (creditLimit = 0, tier?: string) => {
    const created = await prisma.customer.create({
      data: {
        name: `Client devis ${++counter}`,
        creditLimit,
        priceTierId: tier,
      },
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

  const createQuote = (token: string, body: object) =>
    as(token).post('/api/quotes').send(body);

  /// Devis accepté, prêt à convertir.
  const accepted = async (body: object, token = tokens.vendeur) => {
    const quote = (await createQuote(token, body).expect(201)).body;
    await as(token).post(`/api/quotes/${quote.id}/accept`).expect(200);
    return quote;
  };

  const convert = (token: string, id: string, body: object) =>
    as(token)
      .post(`/api/quotes/${id}/convert`)
      .send({ clientMutationId: randomUUID(), ...body });

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
      ['autreVendeur', RoleCode.VENDEUR],
      ['magasinier', RoleCode.MAGASINIER],
    ] as const) {
      const email = `e2e-quote-${key}-${suffix}@test.local`;
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
    for (const key of ['vendeur', 'autreVendeur', 'admin']) {
      await as(tokens[key])
        .post('/api/cash-sessions')
        .send({ locationId: magasinId, openingFloat: 0 })
        .expect(201);
    }
  });

  afterAll(async () => {
    const sales = await prisma.sale.findMany({
      where: { userId: { in: userIds } },
      select: { id: true },
    });
    const quotes = await prisma.quote.findMany({
      where: { userId: { in: userIds } },
      select: { id: true },
    });
    await prisma.auditLog.deleteMany({ where: { userId: { in: userIds } } });
    await prisma.cashMovement.deleteMany({
      where: { userId: { in: userIds } },
    });
    await prisma.sale.deleteMany({
      where: { id: { in: sales.map((s) => s.id) } },
    });
    await prisma.quote.deleteMany({
      where: { id: { in: quotes.map((q) => q.id) } },
    });
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

  describe('création', () => {
    it('au tarif du client, numéroté, et SANS aucun mouvement de stock', async () => {
      const p = await product('5.000');
      const c = await customer(0, grosId);
      const movementsBefore = await prisma.stockMovement.count({
        where: { productId: p },
      });

      const res = await createQuote(tokens.vendeur, {
        customerId: c,
        lines: [{ productId: p, quantity: '2.500' }],
      }).expect(201);

      // Tarif GROS 1 200,00 × 2,5 = 3 000,00 HT ; TVA 19 % = 570,00.
      expect(res.body).toMatchObject({
        status: 'BROUILLON',
        customerId: c,
        totalHt: 300000,
        totalTax: 57000,
        totalTtc: 357000,
        saleId: null,
      });
      expect(res.body.number).toMatch(/^DV-\d{4}-\d{5}$/);
      expect(res.body.lines[0]).toMatchObject({
        quantity: '2.500',
        unitPriceHt: 120000,
      });
      // Règle §8quater : un devis ne touche JAMAIS le stock.
      expect(await stockOf(p)).toBe('5.000');
      expect(
        await prisma.stockMovement.count({ where: { productId: p } }),
      ).toBe(movementsBefore);
    });

    it('un devis peut dépasser le stock : il ne réserve rien', async () => {
      const p = await product('1.000');
      await createQuote(tokens.vendeur, {
        lines: [{ productId: p, quantity: '50' }],
      }).expect(201);
      expect(await stockOf(p)).toBe('1.000');
    });

    it('mêmes règles de prix que la vente : plancher et remise', async () => {
      const p = await product('5.000');
      // Sous le dernier prix d'achat (1 000,00) : refusé comme en vente.
      const below = await createQuote(tokens.vendeur, {
        lines: [
          {
            productId: p,
            quantity: '1',
            unitPriceHt: 50000,
            priceEdited: true,
          },
        ],
      }).expect(422);
      expect(below.body.code).toBe('PRICE_BELOW_COST');

      // Remise : réservée à l'admin.
      const discount = await createQuote(tokens.vendeur, {
        lines: [{ productId: p, quantity: '1', discountAmount: 1000 }],
      }).expect(403);
      expect(discount.body.code).toBe('DISCOUNT_NOT_ALLOWED');
      const admin = await createQuote(tokens.admin, {
        lines: [{ productId: p, quantity: '1', discountAmount: 1000 }],
      }).expect(201);
      expect(admin.body.totalHt).toBe(144000);
    });

    it('date de validité passée : refusée', async () => {
      const p = await product('1.000');
      const hier = localDate(new Date(Date.now() - 24 * 60 * 60 * 1000));
      await createQuote(tokens.vendeur, {
        validUntil: hier,
        lines: [{ productId: p, quantity: '1' }],
      }).expect(422);
    });

    it('droits : ADMIN et VENDEUR, jamais le magasinier', async () => {
      const p = await product('1.000');
      const body = { lines: [{ productId: p, quantity: '1' }] };
      await createQuote(tokens.magasinier, body).expect(403);
      await as(tokens.magasinier).get('/api/quotes').expect(403);
      await request(server).get('/api/quotes').expect(401);
      // Garde de CLASSE : aucune route du contrôleur n'y échappe.
      const quote = (await createQuote(tokens.vendeur, body).expect(201)).body;
      for (const url of [
        `/api/quotes/${quote.id}`,
        `/api/quotes/${quote.id}/pdf`,
      ]) {
        await as(tokens.magasinier).get(url).expect(403);
      }
      for (const action of ['send', 'accept', 'refuse', 'convert']) {
        await as(tokens.magasinier)
          .post(`/api/quotes/${quote.id}/${action}`)
          .send({ clientMutationId: randomUUID(), paidAmount: 0 })
          .expect(403);
      }
    });
  });

  describe('cycle de vie', () => {
    it('BROUILLON → ENVOYE → ACCEPTE, une seule fois', async () => {
      const p = await product('1.000');
      const quote = (
        await createQuote(tokens.vendeur, {
          lines: [{ productId: p, quantity: '1' }],
        }).expect(201)
      ).body;
      await as(tokens.vendeur).post(`/api/quotes/${quote.id}/send`).expect(200);
      const ok = await as(tokens.vendeur)
        .post(`/api/quotes/${quote.id}/accept`)
        .expect(200);
      expect(ok.body.status).toBe('ACCEPTE');
      const again = await as(tokens.vendeur)
        .post(`/api/quotes/${quote.id}/send`)
        .expect(409);
      expect(again.body.code).toBe('INVALID_STATE_TRANSITION');
    });

    it('un devis REFUSÉ ne se convertit pas', async () => {
      const p = await product('1.000');
      const quote = await accepted({
        lines: [{ productId: p, quantity: '1' }],
      });
      await as(tokens.vendeur)
        .post(`/api/quotes/${quote.id}/refuse`)
        .expect(200);
      const res = await convert(tokens.vendeur, quote.id, {
        paidAmount: 0,
      }).expect(409);
      expect(res.body.code).toBe('INVALID_STATE_TRANSITION');
    });

    /// `EXPIRE` n'est jamais écrit : il se LIT d'après la date de validité.
    it('expiré : lu EXPIRE, filtrable, ni accepté ni converti', async () => {
      const p = await product('5.000');
      const today = localDate(new Date());
      const brouillon = (
        await createQuote(tokens.vendeur, {
          validUntil: today,
          lines: [{ productId: p, quantity: '1' }],
        }).expect(201)
      ).body;
      const accepte = await accepted({
        validUntil: today,
        lines: [{ productId: p, quantity: '1' }],
      });
      // Le temps passe : validité au lendemain d'hier.
      await prisma.quote.updateMany({
        where: { id: { in: [brouillon.id, accepte.id] } },
        data: { validUntil: new Date('2020-01-01T00:00:00Z') },
      });

      const lu = await as(tokens.vendeur)
        .get(`/api/quotes/${brouillon.id}`)
        .expect(200);
      expect(lu.body.status).toBe('EXPIRE');
      const filtre = await as(tokens.vendeur)
        .get('/api/quotes?status=EXPIRE&limit=200')
        .expect(200);
      const ids = filtre.body.data.map((q: { id: string }) => q.id);
      expect(ids).toEqual(expect.arrayContaining([brouillon.id, accepte.id]));
      const ouverts = await as(tokens.vendeur)
        .get('/api/quotes?status=BROUILLON&limit=200')
        .expect(200);
      expect(ouverts.body.data.map((q: { id: string }) => q.id)).not.toContain(
        brouillon.id,
      );

      const accept = await as(tokens.vendeur)
        .post(`/api/quotes/${brouillon.id}/accept`)
        .expect(409);
      expect(accept.body.code).toBe('QUOTE_EXPIRED');
      const send = await as(tokens.vendeur)
        .post(`/api/quotes/${brouillon.id}/send`)
        .expect(409);
      expect(send.body.code).toBe('QUOTE_EXPIRED');
      const conv = await convert(tokens.vendeur, accepte.id, {
        paidAmount: 0,
      }).expect(409);
      expect(conv.body.code).toBe('QUOTE_EXPIRED');
      expect(await stockOf(p)).toBe('5.000');
    });
  });

  describe('conversion en vente', () => {
    it('reprend lignes et prix PROMIS, sort le stock, passe CONVERTI', async () => {
      const p = await product('10.000');
      const quote = await accepted({
        lines: [{ productId: p, quantity: '2' }],
      });
      // Le tarif augmente après le devis : la promesse faite au client tient.
      await prisma.productPrice.updateMany({
        where: { productId: p, priceTierId: detailId },
        data: { priceHt: 160000 },
      });

      const sale = (
        await convert(tokens.autreVendeur, quote.id, {
          paidAmount: quote.totalTtc,
        }).expect(201)
      ).body;

      expect(sale.totalTtc).toBe(quote.totalTtc);
      expect(sale.lines[0].unitPriceHt).toBe(145000);
      expect(await stockOf(p)).toBe('8.000');
      const after = await as(tokens.vendeur)
        .get(`/api/quotes/${quote.id}`)
        .expect(200);
      expect(after.body).toMatchObject({ status: 'CONVERTI', saleId: sale.id });
      const row = await prisma.sale.findUniqueOrThrow({
        where: { id: sale.id },
      });
      expect(row.quoteId).toBe(quote.id);
      // Les espèces sont entrées dans la caisse de celui qui convertit.
      const cash = await prisma.cashMovement.findMany({
        where: { saleId: sale.id },
      });
      expect(cash.map((m) => m.amount)).toEqual([quote.totalTtc]);
    });

    it('renvoi de la même clé : la même vente ; autre clé : refusée', async () => {
      const p = await product('10.000');
      const quote = await accepted({
        lines: [{ productId: p, quantity: '1' }],
      });
      const key = randomUUID();
      const body = { clientMutationId: key, paidAmount: quote.totalTtc };
      const first = await as(tokens.vendeur)
        .post(`/api/quotes/${quote.id}/convert`)
        .send(body)
        .expect(201);
      const again = await as(tokens.vendeur)
        .post(`/api/quotes/${quote.id}/convert`)
        .send(body)
        .expect(201);
      expect(again.body.id).toBe(first.body.id);
      expect(await stockOf(p)).toBe('9.000');

      const other = await convert(tokens.vendeur, quote.id, {
        paidAmount: quote.totalTtc,
      }).expect(409);
      expect(other.body.code).toBe('INVALID_STATE_TRANSITION');
      expect(await stockOf(p)).toBe('9.000');
    });

    /// Tout ou rien (règle 3) : une vente refusée laisse le devis ACCEPTÉ.
    it('stock insuffisant : refusée, et le devis reste ACCEPTÉ', async () => {
      const p = await product('1.000');
      const quote = await accepted({
        lines: [{ productId: p, quantity: '3' }],
      });
      await convert(tokens.vendeur, quote.id, {
        paidAmount: quote.totalTtc,
      }).expect(422);
      const lu = await as(tokens.vendeur)
        .get(`/api/quotes/${quote.id}`)
        .expect(200);
      expect(lu.body).toMatchObject({ status: 'ACCEPTE', saleId: null });
      expect(await stockOf(p)).toBe('1.000');
    });

    it('le plancher du coût reste vérifié au jour de la vente', async () => {
      const p = await product('5.000');
      const quote = await accepted({
        lines: [{ productId: p, quantity: '1' }],
      });
      // Une réception plus chère que le prix promis, entre devis et vente.
      await prisma.product.update({
        where: { id: p },
        data: { lastPurchasePriceHt: 150000 },
      });
      const res = await convert(tokens.vendeur, quote.id, {
        paidAmount: quote.totalTtc,
      }).expect(422);
      expect(res.body.code).toBe('PRICE_BELOW_COST');
      expect(
        (await as(tokens.vendeur).get(`/api/quotes/${quote.id}`)).body.status,
      ).toBe('ACCEPTE');
    });

    it('une remise accordée par l’admin dans le devis est reprise par le vendeur', async () => {
      const p = await product('5.000');
      const quote = await accepted(
        { lines: [{ productId: p, quantity: '1', discountAmount: 5000 }] },
        tokens.admin,
      );
      const sale = (
        await convert(tokens.vendeur, quote.id, {
          paidAmount: quote.totalTtc,
        }).expect(201)
      ).body;
      expect(sale.lines[0].discountAmount).toBe(5000);
      expect(sale.totalTtc).toBe(quote.totalTtc);
    });

    it('à crédit : mêmes règles que la vente (client, échéance, plafond)', async () => {
      const p = await product('5.000');
      const comptoir = await accepted({
        lines: [{ productId: p, quantity: '1' }],
      });
      const sansClient = await convert(tokens.vendeur, comptoir.id, {
        paidAmount: 0,
      }).expect(422);
      expect(sansClient.body.code).toBe('CREDIT_LIMIT_EXCEEDED');

      const c = await customer(10_000_000);
      const client = await accepted({
        customerId: c,
        lines: [{ productId: p, quantity: '1' }],
      });
      const sale = (
        await convert(tokens.vendeur, client.id, {
          paidAmount: 0,
          dueDate: '2099-12-31',
        }).expect(201)
      ).body;
      expect(sale.customerId).toBe(c);
      expect(sale.remainingAmount).toBe(client.totalTtc);

      // Au-delà du plafond du client : refusée, le devis reste ACCEPTÉ.
      const petit = await customer(1_000);
      const tropCher = await accepted({
        customerId: petit,
        lines: [{ productId: p, quantity: '1' }],
      });
      const plafond = await convert(tokens.vendeur, tropCher.id, {
        paidAmount: 0,
        dueDate: '2099-12-31',
      }).expect(422);
      expect(plafond.body.code).toBe('CREDIT_LIMIT_EXCEEDED');
      expect(
        (await as(tokens.vendeur).get(`/api/quotes/${tropCher.id}`)).body
          .status,
      ).toBe('ACCEPTE');
    });

    it('seul un devis ACCEPTÉ se convertit', async () => {
      const p = await product('5.000');
      const brouillon = (
        await createQuote(tokens.vendeur, {
          lines: [{ productId: p, quantity: '1' }],
        }).expect(201)
      ).body;
      await convert(tokens.vendeur, brouillon.id, {
        paidAmount: 0,
      }).expect(409);
      expect(await stockOf(p)).toBe('5.000');
    });
  });

  it('PDF : un vrai PDF, même pour un devis comptoir', async () => {
    const p = await product('1.000');
    const quote = (
      await createQuote(tokens.vendeur, {
        lines: [{ productId: p, quantity: '1' }],
      }).expect(201)
    ).body;
    const res = await as(tokens.vendeur)
      .get(`/api/quotes/${quote.id}/pdf`)
      .buffer(true)
      .parse((r, callback) => {
        const chunks: Buffer[] = [];
        r.on('data', (chunk: Buffer) => chunks.push(chunk));
        r.on('end', () => callback(null, Buffer.concat(chunks)));
      })
      .expect(200);
    expect((res.body as Buffer).subarray(0, 5).toString()).toBe('%PDF-');
    expect(res.headers['content-disposition']).toContain(`${quote.number}.pdf`);
  });

  /// Réponse perdue, même id renvoyé : le même devis, jamais un second.
  it('création renvoyée avec le même id : le même devis ; id d’un autre compte : refusé', async () => {
    const p = await product('1.000');
    const id = randomUUID();
    const body = { id, lines: [{ productId: p, quantity: '1' }] };
    const first = await createQuote(tokens.vendeur, body).expect(201);
    const again = await createQuote(tokens.vendeur, body).expect(201);
    expect(again.body.number).toBe(first.body.number);
    expect(await prisma.quote.count({ where: { id } })).toBe(1);
    await createQuote(tokens.autreVendeur, body).expect(409);
  });

  /// Décision 2026-09-22 : une vente à prix modifié est tracée pour l'admin —
  /// y compris quand le prix a transité par un devis.
  it('prix modifié : tracé sur le devis ET sur la vente issue du devis', async () => {
    const p = await product('5.000');
    const quote = await accepted({
      lines: [
        { productId: p, quantity: '1', unitPriceHt: 130000, priceEdited: true },
      ],
    });
    const created = await prisma.auditLog.findFirstOrThrow({
      where: { entityType: 'Quote', entityId: quote.id, action: 'CREATE' },
    });
    expect(created.newValue).toMatchObject({
      priceOverrides: [
        { productId: p, tariffPriceHt: 145000, unitPriceHt: 130000 },
      ],
    });

    const sale = (
      await convert(tokens.vendeur, quote.id, {
        paidAmount: quote.totalTtc,
      }).expect(201)
    ).body;
    const traced = await prisma.auditLog.findFirstOrThrow({
      where: { entityType: 'Sale', entityId: sale.id },
    });
    expect(traced.newValue).toMatchObject({
      quote: quote.number,
      priceOverrides: [
        { productId: p, tariffPriceHt: 145000, unitPriceHt: 130000 },
      ],
    });
  });

  it('au tarif : aucune trace de prix modifié sur la vente', async () => {
    const p = await product('5.000');
    const quote = await accepted({ lines: [{ productId: p, quantity: '1' }] });
    const sale = (
      await convert(tokens.vendeur, quote.id, {
        paidAmount: quote.totalTtc,
      }).expect(201)
    ).body;
    expect(
      await prisma.auditLog.count({
        where: { entityType: 'Sale', entityId: sale.id },
      }),
    ).toBe(0);
  });

  /// Règle 6 de CONVENTIONS.md : tout chemin argent/stock a son test de
  /// concurrence. Le verrou du devis tient la conversion unique.
  describe('conversions simultanées', () => {
    it('deux clés différentes : UNE vente, le stock sort une fois', async () => {
      const p = await product('10.000');
      const quote = await accepted({
        lines: [{ productId: p, quantity: '2' }],
      });
      const [a, b] = await Promise.all([
        convert(tokens.vendeur, quote.id, { paidAmount: quote.totalTtc }),
        convert(tokens.autreVendeur, quote.id, { paidAmount: quote.totalTtc }),
      ]);
      expect([a.status, b.status].sort()).toEqual([201, 409]);
      expect(await prisma.sale.count({ where: { quoteId: quote.id } })).toBe(1);
      expect(await stockOf(p)).toBe('8.000');
    });

    it('la même clé en même temps : la même vente aux deux', async () => {
      const p = await product('10.000');
      const quote = await accepted({
        lines: [{ productId: p, quantity: '1' }],
      });
      const body = {
        clientMutationId: randomUUID(),
        paidAmount: quote.totalTtc,
      };
      const [a, b] = await Promise.all([
        as(tokens.vendeur).post(`/api/quotes/${quote.id}/convert`).send(body),
        as(tokens.vendeur).post(`/api/quotes/${quote.id}/convert`).send(body),
      ]);
      expect([a.status, b.status]).toEqual([201, 201]);
      expect(a.body.id).toBe(b.body.id);
      expect(await stockOf(p)).toBe('9.000');
    });

    it('une clé déjà utilisée pour un AUTRE devis : refusée', async () => {
      const p = await product('10.000');
      const first = await accepted({
        lines: [{ productId: p, quantity: '1' }],
      });
      const second = await accepted({
        lines: [{ productId: p, quantity: '1' }],
      });
      const key = randomUUID();
      await as(tokens.vendeur)
        .post(`/api/quotes/${first.id}/convert`)
        .send({ clientMutationId: key, paidAmount: first.totalTtc })
        .expect(201);
      await as(tokens.vendeur)
        .post(`/api/quotes/${second.id}/convert`)
        .send({ clientMutationId: key, paidAmount: second.totalTtc })
        .expect(409);
      expect(
        (await as(tokens.vendeur).get(`/api/quotes/${second.id}`)).body.status,
      ).toBe('ACCEPTE');
    });
  });
});
