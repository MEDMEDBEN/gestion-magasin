import { randomUUID } from 'crypto';
import * as request from 'supertest';
import { RoleCode } from '../src/common/auth.decorators';
import { Prisma } from '../src/generated/prisma/client';
import { PrismaService } from '../src/prisma/prisma.service';
import { StockLedgerService } from '../src/stock/stock-ledger.service';
import { createE2eApp, createTestUser, E2eApp } from './helpers/e2e-app';

/// Produits dormants et produits demandés (P1 n°20, spec §20).
///
/// Éprouvé en priorité : « sans mouvement » veut dire « sans VENTE » (une
/// réception ne remet PAS l'horloge à zéro, sinon on cache le problème cherché) ;
/// un dormant sans stock ne remonte pas ; et la demande non servie se lit sur
/// l'écart entre demandé et préparé, jamais sur une demande encore en attente.
describe('Rapports produits (e2e)', () => {
  let e2e: E2eApp;
  let prisma: PrismaService;
  let server: E2eApp['server'];
  let ledger: StockLedgerService;

  const suffix = Date.now();
  const PASSWORD = 'MotDePasseTemp1!';
  const userIds: string[] = [];
  const productIds: string[] = [];
  const transferIds: string[] = [];
  const saleIds: string[] = [];
  const tokens: Record<string, string> = {};
  let depotId: string;
  let magasinId: string;
  let counter = 0;

  const as = (token: string) => ({
    get: (url: string) =>
      request(server).get(url).set('Authorization', `Bearer ${token}`),
    post: (url: string) =>
      request(server).post(url).set('Authorization', `Bearer ${token}`),
  });

  const product = async (opts: {
    quantity?: string;
    lastPurchasePriceHt?: number;
    isActive?: boolean;
  }) => {
    const n = ++counter;
    const created = await prisma.product.create({
      data: {
        sku: `E2E-RPT-${suffix}-${n}`,
        barcode: `E2E-RPT-BC-${suffix}-${n}`,
        name: `Produit rapport ${n}`,
        lastPurchasePriceHt: opts.lastPurchasePriceHt ?? null,
        isActive: opts.isActive ?? true,
      },
    });
    productIds.push(created.id);
    if (opts.quantity !== undefined) {
      await prisma.stock.create({
        data: {
          productId: created.id,
          locationId: depotId,
          quantity: opts.quantity,
        },
      });
    }
    return created.id;
  };

  /// Mouvement de stock par le JOURNAL, avec une DATE choisie : c'est cette date
  /// que la dormance regarde. Prisma ne permet pas d'écrire `createdAt` par
  /// `applyMovement`, on la recale juste après — la projection, elle, reste
  /// calculée par le journal.
  const movement = async (
    productId: string,
    quantity: string,
    type: 'VENTE' | 'RECEPTION',
    daysAgo: number,
  ) => {
    const applied = await prisma.$transaction((tx) =>
      ledger.applyMovement(tx, {
        productId,
        locationId: depotId,
        quantity: new Prisma.Decimal(quantity),
        type,
        operationType: type === 'VENTE' ? 'SALE' : 'RECEPTION',
      }),
    );
    await prisma.stockMovement.update({
      where: { id: applied.movementId },
      data: {
        createdAt: new Date(Date.now() - daysAgo * 24 * 60 * 60 * 1000),
      },
    });
  };

  const dormant = async (query = '') =>
    (
      await as(tokens.admin)
        .get(`/api/reports/dormant-products?limit=200${query}`)
        .expect(200)
    ).body;

  /// Une ligne de la réponse. Typée au minimum utile : le contrat complet est
  /// déjà éprouvé par le DTO et le typecheck du service.
  type DormantRow = {
    productId: string;
    lastSoldAt: string | null;
    lastMovementAt: string | null;
  };

  const rowOf = (body: { data: DormantRow[] }, productId: string) =>
    body.data.find((row) => row.productId === productId);

  /// Vente posée en base comme fixture : ce qui est éprouvé ici est la LECTURE
  /// du rapport, pas le chemin de vente (déjà couvert par sa propre suite, et
  /// qui exigerait une session de caisse).
  const sell = async (
    productId: string,
    quantity: string,
    lineTotalHt: number,
    opts: { status?: 'VALIDEE' | 'ANNULEE'; daysAgo?: number } = {},
  ) => {
    const n = ++counter;
    const sale = await prisma.sale.create({
      data: {
        number: `E2E-RPT-V-${suffix}-${n}`,
        status: opts.status ?? 'VALIDEE',
        userId: userIds[0],
        locationId: magasinId,
        totalHt: lineTotalHt,
        totalTax: 0,
        totalTtc: lineTotalHt,
        soldAt: new Date(
          Date.now() - (opts.daysAgo ?? 1) * 24 * 60 * 60 * 1000,
        ),
        lines: {
          create: [
            {
              productId,
              quantity,
              unitPriceHt: lineTotalHt,
              taxRate: 0,
              lineTotalHt,
              lineTaxAmount: 0,
              lineTotalTtc: lineTotalHt,
            },
          ],
        },
      },
    });
    saleIds.push(sale.id);
    return sale.id;
  };

  beforeAll(async () => {
    e2e = await createE2eApp();
    prisma = e2e.prisma;
    server = e2e.server;
    ledger = e2e.app.get(StockLedgerService);
    depotId = (
      await prisma.location.findFirstOrThrow({ where: { type: 'DEPOT' } })
    ).id;
    magasinId = (
      await prisma.location.findFirstOrThrow({ where: { type: 'MAGASIN' } })
    ).id;

    for (const [key, role] of [
      ['admin', RoleCode.ADMIN],
      ['vendeur', RoleCode.VENDEUR],
      ['magasinier', RoleCode.MAGASINIER],
    ] as const) {
      const email = `e2e-rpt-${key}-${suffix}@test.local`;
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
    await prisma.transferLine.deleteMany({
      where: { transferId: { in: transferIds } },
    });
    await prisma.transfer.deleteMany({ where: { id: { in: transferIds } } });
    await prisma.notification.deleteMany({
      where: {
        OR: [{ userId: { in: userIds } }, { operationId: { in: productIds } }],
      },
    });
    await prisma.auditLog.deleteMany({ where: { userId: { in: userIds } } });
    await prisma.stockMovement.deleteMany({
      where: { productId: { in: productIds } },
    });
    await prisma.stock.deleteMany({ where: { productId: { in: productIds } } });
    await prisma.product.deleteMany({ where: { id: { in: productIds } } });
    await prisma.user.deleteMany({ where: { id: { in: userIds } } });
    await e2e.app.close();
  });

  describe('produits dormants', () => {
    it('vendu il y a longtemps, avec du stock : dormant, et la valeur est chiffrée', async () => {
      const id = await product({
        quantity: '39.000',
        lastPurchasePriceHt: 2500,
      });
      await sell(id, '1.000', 5_000, { daysAgo: 200 });

      const row = rowOf(await dormant(), id);
      expect(row).toMatchObject({
        quantity: '39.000',
        // 39 × 25,00 DA = 975,00 DA, en centimes.
        sleepingValueHt: 97_500,
      });
      expect(row!.lastSoldAt).not.toBeNull();
    });

    it('vendu récemment : PAS dormant', async () => {
      const id = await product({ quantity: '40.000' });
      await sell(id, '1.000', 5_000, { daysAgo: 10 });

      expect(rowOf(await dormant(), id)).toBeUndefined();
    });

    /// LE point de la feature : une réception ne doit PAS faire repartir
    /// l'horloge, sinon racheter un produit qui ne part pas — le problème même
    /// qu'on cherche — devient invisible.
    it('reçu hier mais vendu il y a 200 jours : TOUJOURS dormant', async () => {
      const id = await product({ quantity: '10.000' });
      await sell(id, '1.000', 5_000, { daysAgo: 200 });
      await movement(id, '50.000', 'RECEPTION', 1);

      const row = rowOf(await dormant(), id);
      expect(row).toBeDefined();
      // Les deux dates sont rendues : l'écran peut expliquer pourquoi.
      expect(new Date(row!.lastMovementAt as string).getTime()).toBeGreaterThan(
        new Date(row!.lastSoldAt as string).getTime(),
      );
    });

    it('jamais vendu, avec du stock : dormant, sans date de vente', async () => {
      const id = await product({ quantity: '5.000' });

      const row = rowOf(await dormant(), id);
      expect(row).toMatchObject({ lastSoldAt: null });
    });

    it('sans stock : ne remonte pas — rien n’y dort', async () => {
      const id = await product({ quantity: '0.000' });
      expect(rowOf(await dormant(), id)).toBeUndefined();

      const jamaisEnStock = await product({});
      expect(rowOf(await dormant(), jamaisEnStock)).toBeUndefined();
    });

    it('produit désactivé : ne remonte pas', async () => {
      const id = await product({ quantity: '10.000', isActive: false });
      expect(rowOf(await dormant(), id)).toBeUndefined();
    });

    it('le seuil est configurable, et il déplace la frontière', async () => {
      const id = await product({ quantity: '10.000' });
      await sell(id, '1.000', 5_000, { daysAgo: 60 });

      // Seuil 120 jours (défaut) : vendu il y a 60 jours, donc pas dormant.
      expect(rowOf(await dormant(), id)).toBeUndefined();
      // Seuil 30 jours : il le devient.
      expect(rowOf(await dormant('&days=30'), id)).toBeDefined();
    });

    it('le seuil est borné, et le dépassement est refusé', async () => {
      await as(tokens.admin)
        .get('/api/reports/dormant-products?days=3')
        .expect(400);
      await as(tokens.admin)
        .get('/api/reports/dormant-products?days=5000')
        .expect(400);
    });

    /// Les deux moitiés de la feature doivent dire la même chose du même
    /// événement : le rapport de demande ignore une vente annulée, la dormance
    /// aussi. En lisant les mouvements de type VENTE (que l'annulation ne
    /// supprime pas), le produit sortait de la liste pour rien.
    it('une vente ANNULÉE ne sort pas un produit de la liste', async () => {
      const id = await product({ quantity: '10.000' });
      await sell(id, '1.000', 5_000, { daysAgo: 2, status: 'ANNULEE' });

      expect(rowOf(await dormant(), id)).toBeDefined();
    });

    /// L'ordre doit être le même d'un appel à l'autre, sinon la pagination saute
    /// ou double des lignes — la plupart des produits de test n'ont pas de prix,
    /// donc sont à égalité de valeur.
    it('l’ordre est stable entre deux appels', async () => {
      await product({ quantity: '7.000' });
      await product({ quantity: '8.000' });

      const first = (await dormant()).data.map(
        (row: { productId: string }) => row.productId,
      );
      const second = (await dormant()).data.map(
        (row: { productId: string }) => row.productId,
      );
      expect(second).toEqual(first);
    });

    it('la fenêtre de la page couvre bien tous les produits du test', async () => {
      // Si ce garde-fou casse un jour, c'est que la base e2e a grossi : les
      // assertions par `productId` deviendraient intermittentes SANS le dire.
      expect((await dormant()).meta.total).toBeLessThanOrEqual(200);
    });

    it('sans prix d’achat connu : aucune valeur inventée', async () => {
      const id = await product({ quantity: '10.000' });
      expect(rowOf(await dormant(), id)).toMatchObject({
        sleepingValueHt: null,
      });
    });

    it('les trois rôles y ont accès, personne sans token', async () => {
      for (const token of Object.values(tokens)) {
        await as(token).get('/api/reports/dormant-products').expect(200);
      }
      await request(server).get('/api/reports/dormant-products').expect(401);
    });

    /// La preuve doit être SERVEUR (règle 1) : un test sur le menu Flutter ne
    /// prouve rien. Les trois rôles portent `cost.read` aujourd'hui, donc la
    /// seule façon d'exercer la garde est de retirer la permission du rôle — ce
    /// que l'admin peut faire pour de bon. `@RequireFreshAccess` relit les droits
    /// en base, l'effet est donc immédiat, sans nouvelle connexion.
    it('la permission serveur MORD : sans `cost.read`, refusé', async () => {
      const role = await prisma.role.findFirstOrThrow({
        where: { code: 'VENDEUR' },
      });
      const cost = await prisma.permission.findFirstOrThrow({
        where: { code: 'cost.read' },
      });

      await prisma.role.update({
        where: { id: role.id },
        data: { permissions: { disconnect: { id: cost.id } } },
      });
      try {
        await as(tokens.vendeur)
          .get('/api/reports/dormant-products')
          .expect(403);
        // L'autre rapport n'exige pas `cost.read` : il reste ouvert. Les deux
        // routes ne sont donc pas gardées par accident au même endroit.
        await as(tokens.vendeur).get('/api/reports/product-demand').expect(200);
      } finally {
        // Restauré quoi qu'il arrive : la base e2e est partagée par les suites.
        await prisma.role.update({
          where: { id: role.id },
          data: { permissions: { connect: { id: cost.id } } },
        });
      }

      await as(tokens.vendeur).get('/api/reports/dormant-products').expect(200);
    });
  });

  describe('produits demandés', () => {
    /// Demande au dépôt préparée PARTIELLEMENT : l'écart est la demande que la
    /// rupture a fait perdre (spec §20).
    const requestFromWarehouse = async (
      productId: string,
      requested: string,
      prepared: string | null,
    ) => {
      const transfer = (
        await as(tokens.vendeur)
          .post('/api/transfers')
          .send({
            clientMutationId: randomUUID(),
            fromLocationId: depotId,
            toLocationId: magasinId,
            lines: [{ productId, quantity: requested }],
          })
          .expect(201)
      ).body;
      transferIds.push(transfer.id);
      if (prepared === null) return transfer.id as string;

      await as(tokens.magasinier)
        .post(`/api/transfers/${transfer.id}/accept`)
        .expect(200);
      await as(tokens.magasinier)
        .post(`/api/transfers/${transfer.id}/prepare`)
        .send({ lines: [{ productId, preparedQuantity: prepared }] })
        .expect(200);
      return transfer.id as string;
    };

    const demand = async (query = '') =>
      (
        await as(tokens.admin)
          .get(`/api/reports/product-demand${query}`)
          .expect(200)
      ).body;

    it('les plus vendus : quantité ET chiffre d’affaires', async () => {
      const id = await product({ quantity: '100.000' });
      await sell(id, '7.000', 35_000);
      await sell(id, '3.000', 15_000);

      const row = (await demand()).bestSellers.find(
        (r: { productId: string }) => r.productId === id,
      );
      // Les deux ventes s'additionnent : 10 unités, 500,00 DA HT.
      expect(row).toMatchObject({ quantity: '10.000', revenueHt: 50_000 });
    });

    it('une vente ANNULÉE ne compte pas, une vente trop vieille non plus', async () => {
      const annulee = await product({ quantity: '100.000' });
      await sell(annulee, '99.000', 99_000, { status: 'ANNULEE' });

      const vieille = await product({ quantity: '100.000' });
      await sell(vieille, '99.000', 99_000, { daysAgo: 200 });

      const body = await demand(); // fenêtre par défaut : 30 jours
      const ids = body.bestSellers.map(
        (r: { productId: string }) => r.productId,
      );
      expect(ids).not.toContain(annulee);
      expect(ids).not.toContain(vieille);

      // Élargir la fenêtre fait réapparaître la vieille, mais JAMAIS l'annulée.
      const large = await demand('?days=365');
      const largeIds = large.bestSellers.map(
        (r: { productId: string }) => r.productId,
      );
      expect(largeIds).toContain(vieille);
      expect(largeIds).not.toContain(annulee);
    });

    /// Le tableau de bord (n°15) ne montre à un vendeur que SES ventes : ce
    /// rapport ne doit pas lui donner le CA global du magasin par produit. Les
    /// QUANTITÉS restent visibles — c'est une information de rayon.
    it('le chiffre d’affaires est réservé à l’ADMIN, pas les quantités', async () => {
      const id = await product({ quantity: '100.000' });
      await sell(id, '4.000', 20_000);

      const pourLAdmin = (await demand()).bestSellers.find(
        (r: { productId: string }) => r.productId === id,
      );
      expect(pourLAdmin).toMatchObject({
        quantity: '4.000',
        revenueHt: 20_000,
      });

      for (const who of ['vendeur', 'magasinier']) {
        const body = (
          await as(tokens[who]).get('/api/reports/product-demand').expect(200)
        ).body;
        const row = body.bestSellers.find(
          (r: { productId: string }) => r.productId === id,
        );
        // La quantité oui, le montant non — et `null`, jamais 0 : un zéro se
        // lirait « rien vendu ».
        expect(row).toMatchObject({ quantity: '4.000', revenueHt: null });
      }
    });

    it('demandé au dépôt : remonte dans « les plus demandés »', async () => {
      const id = await product({ quantity: '100.000' });
      await requestFromWarehouse(id, '30.000', null);

      const body = await demand();
      const row = body.mostRequested.find(
        (r: { productId: string }) => r.productId === id,
      );
      expect(row).toMatchObject({ quantity: '30.000', revenueHt: null });
    });

    it('préparé en moins : l’écart remonte dans « demandés non servis »', async () => {
      const id = await product({ quantity: '100.000' });
      await requestFromWarehouse(id, '30.000', '12.000');

      const body = await demand();
      const row = body.unmetDemand.find(
        (r: { productId: string }) => r.productId === id,
      );
      // 30 demandés, 12 préparés : 18 perdus.
      expect(row).toMatchObject({ quantity: '18.000' });
    });

    /// Sur une demande encore en attente, `preparedQuantity` vaut 0 : compter
    /// l'écart ferait lire « rupture » là où rien n'a encore été fait.
    it('une demande PAS ENCORE préparée ne compte pas comme non servie', async () => {
      const id = await product({ quantity: '100.000' });
      await requestFromWarehouse(id, '30.000', null);

      const body = await demand();
      expect(
        body.unmetDemand.find((r: { productId: string }) => r.productId === id),
      ).toBeUndefined();
    });

    it('servi en entier : rien dans « non servis »', async () => {
      const id = await product({ quantity: '100.000' });
      await requestFromWarehouse(id, '20.000', '20.000');

      const body = await demand();
      expect(
        body.unmetDemand.find((r: { productId: string }) => r.productId === id),
      ).toBeUndefined();
    });

    it('la fenêtre est bornée et rendue dans la réponse', async () => {
      expect((await demand()).days).toBe(30);
      expect((await demand('?days=90')).days).toBe(90);
      await as(tokens.admin)
        .get('/api/reports/product-demand?days=2')
        .expect(400);
    });

    it('les trois rôles y ont accès, personne sans token', async () => {
      for (const token of Object.values(tokens)) {
        await as(token).get('/api/reports/product-demand').expect(200);
      }
      await request(server).get('/api/reports/product-demand').expect(401);
    });
  });
});
