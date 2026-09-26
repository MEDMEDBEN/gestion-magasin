import { randomUUID } from 'crypto';
import { Workbook } from 'exceljs';
import * as request from 'supertest';
import { RoleCode } from '../src/common/auth.decorators';
import { localDate } from '../src/common/document-number';
import { PrismaService } from '../src/prisma/prisma.service';
import { createE2eApp, createTestUser, E2eApp } from './helpers/e2e-app';

/// Rapports ventes / stock / achats (P1 n°21, spec §21).
///
/// Éprouvé en priorité : `to` est INCLUS (sinon « du 1er au 30 » perd le 30) ;
/// la marge vaut `null` quand le coût est inconnu au lieu d'égaler le CA ;
/// commandé et reçu ne s'équilibrent pas ; et ces rapports sont fermés à tout
/// le monde sauf l'admin.
describe('Rapports d’activité (e2e)', () => {
  let e2e: E2eApp;
  let prisma: PrismaService;
  let server: E2eApp['server'];

  const suffix = Date.now();
  const PASSWORD = 'MotDePasseTemp1!';
  const userIds: string[] = [];
  const productIds: string[] = [];
  const supplierIds: string[] = [];
  const categoryIds: string[] = [];
  const saleIds: string[] = [];
  const orderIds: string[] = [];
  const receptionIds: string[] = [];
  const tokens: Record<string, string> = {};
  let magasinId: string;
  let depotId: string;
  let counter = 0;

  const as = (token: string) => ({
    get: (url: string) =>
      request(server).get(url).set('Authorization', `Bearer ${token}`),
  });

  const DAY = 24 * 60 * 60 * 1000;
  /// Jour CIVIL d'Alger d'il y a N jours — le serveur borne les périodes en
  /// jours d'Alger ; un jour UTC ferait vaciller les tests entre 23 h et minuit.
  const iso = (daysAgo: number) =>
    localDate(new Date(Date.now() - daysAgo * DAY));
  /// Lendemain d'un jour `AAAA-MM-JJ`.
  const nextDay = (day: string) =>
    new Date(Date.parse(`${day}T00:00:00Z`) + DAY).toISOString().slice(0, 10);

  const product = async (opts: {
    lastPurchasePriceHt?: number;
    categoryId?: string;
    minThreshold?: string;
    stock?: { locationId: string; quantity: string }[];
  }) => {
    const n = ++counter;
    const created = await prisma.product.create({
      data: {
        sku: `E2E-BRP-${suffix}-${n}`,
        barcode: `E2E-BRP-BC-${suffix}-${n}`,
        name: `Produit rapport activité ${n}`,
        lastPurchasePriceHt: opts.lastPurchasePriceHt ?? null,
        categoryId: opts.categoryId ?? null,
        minThreshold: opts.minThreshold ?? '0',
      },
    });
    productIds.push(created.id);
    for (const row of opts.stock ?? []) {
      await prisma.stock.create({
        data: {
          productId: created.id,
          locationId: row.locationId,
          quantity: row.quantity,
        },
      });
    }
    return created.id;
  };

  /// Vente posée en base : ce qui est éprouvé est la LECTURE du rapport, pas le
  /// chemin de vente (couvert par sa propre suite, et qui exige une caisse).
  const sell = async (
    lines: { productId: string; quantity: string; lineTotalHt: number }[],
    opts: {
      daysAgo?: number;
      status?: 'VALIDEE' | 'ANNULEE';
      tax?: number;
      discount?: number;
      soldAt?: Date;
    } = {},
  ) => {
    const n = ++counter;
    const totalHt = lines.reduce((sum, line) => sum + line.lineTotalHt, 0);
    const tax = opts.tax ?? 0;
    const sale = await prisma.sale.create({
      data: {
        number: `E2E-BRP-V-${suffix}-${n}`,
        status: opts.status ?? 'VALIDEE',
        userId: userIds[0],
        locationId: magasinId,
        totalHt,
        totalTax: tax,
        totalTtc: totalHt + tax,
        soldAt:
          opts.soldAt ??
          new Date(Date.now() - (opts.daysAgo ?? 1) * 24 * 60 * 60 * 1000),
        lines: {
          create: lines.map((line) => ({
            productId: line.productId,
            quantity: line.quantity,
            unitPriceHt: line.lineTotalHt,
            taxRate: 0,
            discountAmount: opts.discount ?? 0,
            lineTotalHt: line.lineTotalHt,
            lineTaxAmount: 0,
            lineTotalTtc: line.lineTotalHt,
          })),
        },
      },
    });
    saleIds.push(sale.id);
    return sale.id;
  };

  const order = async (
    supplierId: string,
    totalHt: number,
    opts: {
      daysAgo?: number;
      status?: 'COMMANDEE' | 'BROUILLON' | 'ANNULEE';
    } = {},
  ) => {
    const n = ++counter;
    const created = await prisma.purchaseOrder.create({
      data: {
        number: `E2E-BRP-C-${suffix}-${n}`,
        supplierId,
        status: opts.status ?? 'COMMANDEE',
        createdById: userIds[0],
        orderDate: new Date(
          Date.now() - (opts.daysAgo ?? 1) * 24 * 60 * 60 * 1000,
        ),
        totalHt,
        totalTax: 0,
        totalTtc: totalHt,
      },
    });
    orderIds.push(created.id);
    return created.id;
  };

  const receive = async (
    supplierId: string,
    lines: { productId: string; quantity: string; unitPriceHt: number }[],
    daysAgo = 1,
  ) => {
    const n = ++counter;
    const created = await prisma.reception.create({
      data: {
        number: `E2E-BRP-R-${suffix}-${n}`,
        supplierId,
        locationId: depotId,
        userId: userIds[0],
        receivedAt: new Date(Date.now() - daysAgo * 24 * 60 * 60 * 1000),
        clientMutationId: randomUUID(),
        lines: {
          create: lines.map((line) => ({
            productId: line.productId,
            receivedQuantity: line.quantity,
            unitPriceHt: line.unitPriceHt,
          })),
        },
      },
    });
    receptionIds.push(created.id);
    return created.id;
  };

  const salesReport = async (query = '') =>
    (await as(tokens.admin).get(`/api/reports/sales${query}`).expect(200)).body;

  beforeAll(async () => {
    e2e = await createE2eApp();
    prisma = e2e.prisma;
    server = e2e.server;
    magasinId = (
      await prisma.location.findFirstOrThrow({ where: { type: 'MAGASIN' } })
    ).id;
    depotId = (
      await prisma.location.findFirstOrThrow({ where: { type: 'DEPOT' } })
    ).id;

    for (const [key, role] of [
      ['admin', RoleCode.ADMIN],
      ['vendeur', RoleCode.VENDEUR],
      ['magasinier', RoleCode.MAGASINIER],
    ] as const) {
      const email = `e2e-brp-${key}-${suffix}@test.local`;
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
    await prisma.saleLine.deleteMany({ where: { saleId: { in: saleIds } } });
    await prisma.sale.deleteMany({ where: { id: { in: saleIds } } });
    await prisma.receptionLine.deleteMany({
      where: { receptionId: { in: receptionIds } },
    });
    await prisma.reception.deleteMany({ where: { id: { in: receptionIds } } });
    await prisma.purchaseOrder.deleteMany({ where: { id: { in: orderIds } } });
    await prisma.auditLog.deleteMany({ where: { userId: { in: userIds } } });
    await prisma.stockMovement.deleteMany({
      where: { productId: { in: productIds } },
    });
    await prisma.stock.deleteMany({ where: { productId: { in: productIds } } });
    await prisma.product.deleteMany({ where: { id: { in: productIds } } });
    await prisma.category.deleteMany({ where: { id: { in: categoryIds } } });
    await prisma.supplier.deleteMany({ where: { id: { in: supplierIds } } });
    await prisma.user.deleteMany({ where: { id: { in: userIds } } });
    await e2e.app.close();
  });

  describe('rapport des ventes', () => {
    it('somme le CA, la TVA et les remises des ventes VALIDÉES', async () => {
      const id = await product({ lastPurchasePriceHt: 1000 });
      await sell([{ productId: id, quantity: '2.000', lineTotalHt: 5_000 }], {
        tax: 950,
        discount: 200,
        daysAgo: 340,
      });

      // Fenêtre isolée : des égalités exactes, pas des « au moins ».
      const body = await salesReport(`?from=${iso(341)}&to=${iso(339)}`);
      expect(body.totals.count).toBe(1);
      expect(body.totals.revenueHt).toBe(5_000);
      expect(body.totals.taxAmount).toBe(950);
      expect(body.totals.revenueTtc).toBe(5_950);
      expect(body.totals.discountAmount).toBe(200);
    });

    it('une vente ANNULÉE n’est pas du chiffre d’affaires', async () => {
      const id = await product({});
      const avant = (await salesReport(`?from=${iso(3)}&to=${iso(0)}`)).totals;
      await sell([{ productId: id, quantity: '1.000', lineTotalHt: 999_999 }], {
        status: 'ANNULEE',
        daysAgo: 1,
      });
      const apres = (await salesReport(`?from=${iso(3)}&to=${iso(0)}`)).totals;

      expect(apres.revenueHt).toBe(avant.revenueHt);
      expect(apres.count).toBe(avant.count);
    });

    /// LE piège des bornes : sans borne haute exclusive au lendemain, une vente
    /// du dernier jour de la période disparaît du rapport.
    it('`to` est INCLUS : la vente du dernier jour compte', async () => {
      const id = await product({});
      await sell([{ productId: id, quantity: '1.000', lineTotalHt: 7_000 }], {
        daysAgo: 5,
      });

      // Période qui S'ARRÊTE au jour de la vente.
      const body = await salesReport(`?from=${iso(5)}&to=${iso(5)}`);
      expect(body.period.days).toBe(1);
      expect(body.totals.revenueHt).toBeGreaterThanOrEqual(7_000);
    });

    it('hors période : la vente ne compte pas', async () => {
      const id = await product({});
      await sell([{ productId: id, quantity: '1.000', lineTotalHt: 123_456 }], {
        daysAgo: 400,
      });

      const body = await salesReport(`?from=${iso(10)}&to=${iso(0)}`);
      expect(body.totals.revenueHt).toBeLessThan(123_456);
    });

    /// Une marge égale au CA serait un chiffre faux et flatteur : sans coût
    /// connu, on ne prétend pas savoir.
    it('marge `null` quand AUCUN produit vendu n’a de coût connu', async () => {
      const sansCout = await product({});
      await sell(
        [{ productId: sansCout, quantity: '1.000', lineTotalHt: 4_000 }],
        { daysAgo: 300 },
      );

      // Fenêtre isolée autour de cette seule vente.
      const body = await salesReport(`?from=${iso(301)}&to=${iso(299)}`);
      expect(body.totals.revenueHt).toBe(4_000);
      expect(body.totals.costHt).toBeNull();
      expect(body.totals.marginHt).toBeNull();
    });

    it('marge = CA − coût, au DERNIER prix d’achat (règle 5)', async () => {
      const avecCout = await product({ lastPurchasePriceHt: 1_500 });
      await sell(
        [{ productId: avecCout, quantity: '3.000', lineTotalHt: 9_000 }],
        { daysAgo: 310 },
      );

      const body = await salesReport(`?from=${iso(311)}&to=${iso(309)}`);
      // 3 × 15,00 DA = 45,00 DA de coût ; 90,00 − 45,00 = 45,00 de marge.
      expect(body.totals.costHt).toBe(4_500);
      expect(body.totals.marginHt).toBe(4_500);
      expect(body.totals.uncostedRevenueHt).toBe(0);
    });

    /// Le piège du coût PARTIEL : retrancher le coût des seuls produits connus
    /// du CA de TOUS les produits compte les ventes sans coût comme de la marge
    /// pure. Au démarrage, une bonne partie du catalogue n'a pas de coût.
    it('coût PARTIEL : la marge ne porte que sur le CA des produits au coût connu', async () => {
      const avecCout = await product({ lastPurchasePriceHt: 1_000 });
      const sansCout = await product({});
      await sell(
        [
          { productId: avecCout, quantity: '1.000', lineTotalHt: 10_000 },
          { productId: sansCout, quantity: '1.000', lineTotalHt: 100_000 },
        ],
        { daysAgo: 370 },
      );

      const body = await salesReport(`?from=${iso(371)}&to=${iso(369)}`);
      expect(body.totals.revenueHt).toBe(110_000);
      expect(body.totals.costHt).toBe(1_000);
      // 100,00 − 10,00 DA, et non 1 100,00 − 10,00.
      expect(body.totals.marginHt).toBe(9_000);
      expect(body.totals.uncostedRevenueHt).toBe(100_000);
    });

    it('coût d’une quantité décimale : arrondi au centime entier', async () => {
      // 0,333 m × 10,01 DA = 3,33333 DA → 333 centimes.
      const cable = await product({ lastPurchasePriceHt: 1_001 });
      await sell([{ productId: cable, quantity: '0.333', lineTotalHt: 500 }], {
        daysAgo: 380,
      });

      const body = await salesReport(`?from=${iso(381)}&to=${iso(379)}`);
      expect(body.totals.costHt).toBe(333);
      expect(body.totals.marginHt).toBe(167);
    });

    /// Les jours d'une période sont des jours d'ALGER. `soldAt` est en UTC :
    /// 23 h 30 UTC est déjà le lendemain à Alger, 00 h 30 UTC est 01 h 30 le
    /// même jour. Les totaux ET la courbe doivent le dire.
    it('jours civils d’Alger : bornes et courbe', async () => {
      const x = iso(390);
      const y = nextDay(nextDay(nextDay(x)));
      const id = await product({});
      // X à 23 h 30 UTC = X+1 à 00 h 30 à Alger.
      await sell([{ productId: id, quantity: '1.000', lineTotalHt: 1_100 }], {
        soldAt: new Date(`${x}T23:30:00Z`),
      });
      // Y à 00 h 30 UTC = Y à 01 h 30 à Alger.
      await sell([{ productId: id, quantity: '1.000', lineTotalHt: 2_200 }], {
        soldAt: new Date(`${y}T00:30:00Z`),
      });

      const surX = await salesReport(`?from=${x}&to=${x}`);
      expect(surX.totals.revenueHt).toBe(0);

      const lendemain = await salesReport(
        `?from=${nextDay(x)}&to=${nextDay(x)}`,
      );
      expect(lendemain.totals.revenueHt).toBe(1_100);
      expect(lendemain.byDay).toEqual([
        { date: nextDay(x), count: 1, revenueHt: 1_100 },
      ]);

      const surY = await salesReport(`?from=${y}&to=${y}`);
      expect(surY.totals.revenueHt).toBe(2_200);
      expect(surY.byDay).toEqual([{ date: y, count: 1, revenueHt: 2_200 }]);
    });

    it('ventile par catégorie, et nomme celle qui manque', async () => {
      const category = await prisma.category.create({
        data: { name: `Câbles ${suffix}` },
      });
      categoryIds.push(category.id);
      const range = `?from=${iso(321)}&to=${iso(319)}`;

      const classe = await product({ categoryId: category.id });
      const sans = await product({});
      await sell(
        [{ productId: classe, quantity: '2.000', lineTotalHt: 8_000 }],
        {
          daysAgo: 320,
        },
      );
      await sell([{ productId: sans, quantity: '1.000', lineTotalHt: 3_000 }], {
        daysAgo: 320,
      });

      const body = await salesReport(range);
      const noms = body.byCategory.map(
        (r: { categoryName: string }) => r.categoryName,
      );
      expect(noms).toContain(`Câbles ${suffix}`);
      expect(noms).toContain('Sans catégorie');
      // CA décroissant : la catégorie la plus vendue d'abord.
      expect(body.byCategory[0].revenueHt).toBe(8_000);
    });

    it('un point par jour ayant eu des ventes, par date croissante', async () => {
      const id = await product({});
      await sell([{ productId: id, quantity: '1.000', lineTotalHt: 1_000 }], {
        daysAgo: 331,
      });
      await sell([{ productId: id, quantity: '1.000', lineTotalHt: 2_000 }], {
        daysAgo: 330,
      });

      const body = await salesReport(`?from=${iso(332)}&to=${iso(329)}`);
      expect(body.byDay).toHaveLength(2);
      expect(body.byDay[0].date < body.byDay[1].date).toBe(true);
      expect(body.byDay.map((r: { revenueHt: number }) => r.revenueHt)).toEqual(
        [1_000, 2_000],
      );
    });

    it('période invalide ou trop longue : refusée', async () => {
      await as(tokens.admin)
        .get(`/api/reports/sales?from=${iso(0)}&to=${iso(10)}`)
        .expect(400);
      await as(tokens.admin)
        .get(`/api/reports/sales?from=${iso(900)}&to=${iso(0)}`)
        .expect(400);
      await as(tokens.admin)
        .get('/api/reports/sales?from=pas-une-date')
        .expect(400);
      // Un JOUR, pas un instant : l'heure et le fuseau rendraient les bornes
      // et le nombre de jours incohérents.
      await as(tokens.admin)
        .get('/api/reports/sales?from=2026-09-01T15:00:00%2B05:00')
        .expect(400);
      // Les achats passent par la même validation.
      await as(tokens.admin)
        .get('/api/reports/purchases?from=pas-une-date')
        .expect(400);
    });

    it('sans période : les 30 derniers jours, aujourd’hui compris', async () => {
      const body = await salesReport();
      expect(body.period.days).toBe(30);
      expect(body.period.to).toBe(iso(0));
      expect(body.period.from).toBe(iso(29));
    });
  });

  describe('rapport de stock', () => {
    const stockReport = async () =>
      (await as(tokens.admin).get('/api/reports/stock').expect(200)).body;

    const valueAt = (
      body: { byLocation: { locationId: string; valueHt: number | null }[] },
      locationId: string,
    ) => body.byLocation.find((r) => r.locationId === locationId)?.valueHt ?? 0;

    it('valorise au dernier prix d’achat, magasin et dépôt séparés', async () => {
      const avant = await stockReport();
      await product({
        lastPurchasePriceHt: 2_000,
        stock: [
          { locationId: magasinId, quantity: '3.000' },
          { locationId: depotId, quantity: '2.000' },
        ],
      });
      const apres = await stockReport();

      // 3 × 20,00 DA au magasin, 2 × 20,00 DA au dépôt.
      expect(valueAt(apres, magasinId) - valueAt(avant, magasinId)).toBe(6_000);
      expect(valueAt(apres, depotId) - valueAt(avant, depotId)).toBe(4_000);
      expect(apres.valueHt - (avant.valueHt ?? 0)).toBe(10_000);
      expect(apres.referenceCount).toBe(avant.referenceCount + 1);
    });

    it('quantité décimale : valeur arrondie au centime entier', async () => {
      const avant = await stockReport();
      await product({
        lastPurchasePriceHt: 1_001,
        stock: [{ locationId: depotId, quantity: '0.333' }],
      });
      const apres = await stockReport();

      expect(apres.valueHt - (avant.valueHt ?? 0)).toBe(333);
    });

    /// Un emplacement en négatif (vendu d'avance) : le total suit la quantité
    /// NETTE du produit, comme le compteur de références.
    it('emplacement négatif : le total valorise la quantité nette', async () => {
      const avant = await stockReport();
      await product({
        lastPurchasePriceHt: 1_000,
        stock: [
          { locationId: magasinId, quantity: '-2.000' },
          { locationId: depotId, quantity: '5.000' },
        ],
      });
      const apres = await stockReport();

      expect(apres.valueHt - (avant.valueHt ?? 0)).toBe(3_000);
      // L'emplacement, lui, montre ce qu'il a en rayon.
      expect(valueAt(apres, depotId) - valueAt(avant, depotId)).toBe(5_000);
      expect(valueAt(apres, magasinId)).toBe(valueAt(avant, magasinId));
    });

    /// Valoriser à zéro un produit sans coût connu ferait croire à un stock qui
    /// ne vaut rien : il est compté à part.
    it('un produit sans coût connu est compté à part, pas valorisé à zéro', async () => {
      const avant = await stockReport();
      await product({ stock: [{ locationId: depotId, quantity: '5.000' }] });
      const apres = await stockReport();

      expect(apres.withoutCostCount).toBe(avant.withoutCostCount + 1);
      expect(apres.valueHt).toBe(avant.valueHt);
    });

    it('compte les stocks faibles et les ruptures', async () => {
      const avant = await stockReport();
      await product({
        minThreshold: '20.000',
        stock: [{ locationId: depotId, quantity: '5.000' }],
      });
      await product({
        minThreshold: '20.000',
        stock: [{ locationId: depotId, quantity: '0.000' }],
      });
      const apres = await stockReport();

      expect(apres.lowCount).toBe(avant.lowCount + 2);
      expect(apres.outOfStockCount).toBe(avant.outOfStockCount + 1);
    });

    it('le transit n’est pas du stock valorisable', async () => {
      const transit = await prisma.location.findFirstOrThrow({
        where: { type: 'TRANSIT' },
      });
      const avant = await stockReport();
      await product({
        lastPurchasePriceHt: 10_000,
        stock: [{ locationId: transit.id, quantity: '50.000' }],
      });
      const apres = await stockReport();

      expect(apres.valueHt).toBe(avant.valueHt);
      expect(
        apres.byLocation.map((r: { locationId: string }) => r.locationId),
      ).not.toContain(transit.id);
    });
  });

  describe('rapport des achats', () => {
    const purchasesReport = async (query = '') =>
      (await as(tokens.admin).get(`/api/reports/purchases${query}`).expect(200))
        .body;

    const supplier = async () => {
      const created = await prisma.supplier.create({
        data: { name: `Fournisseur rapport ${++counter} ${suffix}` },
      });
      supplierIds.push(created.id);
      return created.id;
    };

    it('somme le commandé et le reçu, séparément, par fournisseur', async () => {
      const id = await supplier();
      const p = await product({});
      await order(id, 40_000, { daysAgo: 350 });
      await receive(
        id,
        [{ productId: p, quantity: '2.000', unitPriceHt: 5_000 }],
        350,
      );

      const body = await purchasesReport(`?from=${iso(351)}&to=${iso(349)}`);
      expect(body.orderedHt).toBe(40_000);
      // 2 × 50,00 DA = 100,00 DA reçus, et non le montant commandé.
      expect(body.receivedHt).toBe(10_000);
      expect(body.receptionCount).toBe(1);

      const ligne = body.bySupplier.find(
        (r: { supplierId: string }) => r.supplierId === id,
      );
      expect(ligne).toMatchObject({
        orderCount: 1,
        orderedHt: 40_000,
        receivedHt: 10_000,
      });
    });

    it('un BROUILLON ou une commande ANNULÉE n’engage rien', async () => {
      const id = await supplier();
      await order(id, 999_999, { daysAgo: 360, status: 'BROUILLON' });
      await order(id, 888_888, { daysAgo: 360, status: 'ANNULEE' });

      const body = await purchasesReport(`?from=${iso(361)}&to=${iso(359)}`);
      expect(body.orderCount).toBe(0);
      expect(body.orderedHt).toBe(0);
    });
  });

  /// Les fichiers disent les MÊMES chiffres que l'écran, et ne s'ouvrent pas à
  /// plus de monde que lui.
  describe('exports', () => {
    const EXPORTS = ['sales', 'stock', 'purchases'].map(
      (route) => `/api/reports/${route}/export`,
    );

    const download = (token: string, url: string) =>
      request(server)
        .get(url)
        .set('Authorization', `Bearer ${token}`)
        .buffer(true)
        .parse((res, callback) => {
          const chunks: Buffer[] = [];
          res.on('data', (chunk: Buffer) => chunks.push(chunk));
          res.on('end', () => callback(null, Buffer.concat(chunks)));
        });

    it('ventes en Excel : les chiffres du rapport, en nombres', async () => {
      const id = await product({ lastPurchasePriceHt: 1_000 });
      await sell([{ productId: id, quantity: '2.000', lineTotalHt: 12_345 }], {
        tax: 2_345,
        daysAgo: 400,
      });
      const range = `from=${iso(401)}&to=${iso(399)}`;

      const res = await download(
        tokens.admin,
        `/api/reports/sales/export?format=xlsx&${range}`,
      ).expect(200);
      expect(res.headers['content-type']).toContain('spreadsheetml');
      expect(res.headers['content-disposition']).toBe(
        `attachment; filename="rapport-ventes_${iso(401)}_${iso(399)}.xlsx"`,
      );

      const book = new Workbook();
      await book.xlsx.load(res.body as ArrayBuffer);
      const values = book.worksheets[0]
        .getSheetValues()
        .flatMap((row) => (Array.isArray(row) ? row : []));
      // Les MÊMES chiffres que l'écran sur la même période (la base e2e est
      // partagée : on compare au rapport, pas à une fenêtre supposée vide).
      const { totals } = await salesReport(`?${range}`);
      expect(totals.revenueHt).toBeGreaterThanOrEqual(12_345);
      expect(values).toEqual(
        expect.arrayContaining(
          [totals.revenueHt, totals.costHt, totals.marginHt].map(
            (centimes: number) => centimes / 100,
          ),
        ),
      );
    });

    it('achats en CSV : montants exacts à la française', async () => {
      const fournisseur = await prisma.supplier.create({
        data: { name: `Fournisseur export ${suffix}` },
      });
      supplierIds.push(fournisseur.id);
      await order(fournisseur.id, 150_075, { daysAgo: 410 });

      const res = await download(
        tokens.admin,
        `/api/reports/purchases/export?format=csv&from=${iso(411)}&to=${iso(409)}`,
      ).expect(200);
      const text = (res.body as Buffer).toString('utf8');
      expect(text).toContain(`Fournisseur export ${suffix};1;1500,75;0,00`);
    });

    it('stock en PDF : un vrai PDF', async () => {
      const res = await download(
        tokens.admin,
        '/api/reports/stock/export?format=pdf',
      ).expect(200);
      expect((res.body as Buffer).subarray(0, 5).toString()).toBe('%PDF-');
      expect(res.headers['content-disposition']).toMatch(
        /^attachment; filename="rapport-stock_\d{4}-\d{2}-\d{2}\.pdf"$/,
      );
    });

    it('format absent ou inconnu : refusé', async () => {
      for (const url of EXPORTS) {
        await as(tokens.admin).get(url).expect(400);
        await as(tokens.admin).get(`${url}?format=docx`).expect(400);
      }
      // La période est validée comme pour la lecture.
      await as(tokens.admin)
        .get('/api/reports/sales/export?format=csv&from=pas-une-date')
        .expect(400);
    });

    it('un fichier n’ouvre pas plus de portes que l’écran', async () => {
      for (const url of EXPORTS) {
        for (const who of ['vendeur', 'magasinier']) {
          await as(tokens[who]).get(`${url}?format=csv`).expect(403);
        }
        await request(server).get(`${url}?format=csv`).expect(401);
      }
    });

    it('admin rétrogradé : plus aucun export, avec le même jeton', async () => {
      const email = `e2e-brp-retro-export-${suffix}@test.local`;
      const user = await createTestUser(prisma, {
        email,
        password: PASSWORD,
        roles: [RoleCode.ADMIN],
      });
      userIds.push(user.id);
      const token = (
        await request(server)
          .post('/api/auth/login')
          .send({ identifier: email, password: PASSWORD })
          .expect(200)
      ).body.accessToken;

      await as(token).get(`${EXPORTS[0]}?format=csv`).expect(200);
      await prisma.user.update({
        where: { id: user.id },
        data: { roles: { set: [{ code: RoleCode.VENDEUR }] } },
      });
      for (const url of EXPORTS) {
        await as(token).get(`${url}?format=csv`).expect(403);
      }
    });
  });

  describe('qui y a droit', () => {
    it('ADMIN seul : ni vendeur ni magasinier', async () => {
      for (const route of ['sales', 'stock', 'purchases']) {
        await as(tokens.admin).get(`/api/reports/${route}`).expect(200);
        for (const who of ['vendeur', 'magasinier']) {
          await as(tokens[who]).get(`/api/reports/${route}`).expect(403);
        }
        await request(server).get(`/api/reports/${route}`).expect(401);
      }
    });

    /// Les rapports PRODUITS (n°20) restent ouverts aux trois rôles : les deux
    /// familles ne se confondent pas, et une garde trop large sur `reports/`
    /// aurait fermé les deux.
    /// Le 403 du vendeur vient déjà du rôle porté par le JETON : ce test prouve
    /// autre chose — que les droits sont relus EN BASE (`@RequireFreshAccess`).
    /// Sans cette relecture, un admin rétrogradé lirait CA et marge pendant les
    /// 15 minutes de son jeton.
    it('admin rétrogradé : refusé tout de suite, avec le même jeton', async () => {
      const email = `e2e-brp-retro-${suffix}@test.local`;
      const user = await createTestUser(prisma, {
        email,
        password: PASSWORD,
        roles: [RoleCode.ADMIN],
      });
      userIds.push(user.id);
      const token = (
        await request(server)
          .post('/api/auth/login')
          .send({ identifier: email, password: PASSWORD })
          .expect(200)
      ).body.accessToken;

      for (const route of ['sales', 'stock', 'purchases']) {
        await as(token).get(`/api/reports/${route}`).expect(200);
      }
      await prisma.user.update({
        where: { id: user.id },
        data: { roles: { set: [{ code: RoleCode.VENDEUR }] } },
      });
      for (const route of ['sales', 'stock', 'purchases']) {
        await as(token).get(`/api/reports/${route}`).expect(403);
      }
    });

    it('cumul vendeur + magasinier : toujours refusé', async () => {
      const email = `e2e-brp-cumul-${suffix}@test.local`;
      const user = await createTestUser(prisma, {
        email,
        password: PASSWORD,
        roles: [RoleCode.VENDEUR, RoleCode.MAGASINIER],
      });
      userIds.push(user.id);
      const token = (
        await request(server)
          .post('/api/auth/login')
          .send({ identifier: email, password: PASSWORD })
          .expect(200)
      ).body.accessToken;
      for (const route of ['sales', 'stock', 'purchases']) {
        await as(token).get(`/api/reports/${route}`).expect(403);
      }
    });

    it('les rapports produits restent ouverts aux trois rôles', async () => {
      for (const who of ['vendeur', 'magasinier']) {
        await as(tokens[who]).get('/api/reports/dormant-products').expect(200);
        await as(tokens[who]).get('/api/reports/product-demand').expect(200);
      }
    });
  });

  it('les montants sont des ENTIERS de centimes, jamais des décimaux', async () => {
    const body = await salesReport();
    for (const value of [
      body.totals.revenueHt,
      body.totals.taxAmount,
      body.totals.revenueTtc,
      body.totals.discountAmount,
      body.totals.uncostedRevenueHt,
    ]) {
      expect(Number.isInteger(value)).toBe(true);
    }
    const stock = (await as(tokens.admin).get('/api/reports/stock').expect(200))
      .body;
    if (stock.valueHt !== null)
      expect(Number.isInteger(stock.valueHt)).toBe(true);
  });
});
