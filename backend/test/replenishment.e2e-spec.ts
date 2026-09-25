import { randomUUID } from 'crypto';
import * as request from 'supertest';
import { RoleCode } from '../src/common/auth.decorators';
import { Prisma } from '../src/generated/prisma/client';
import { StockLedgerService } from '../src/stock/stock-ledger.service';
import { PrismaService } from '../src/prisma/prisma.service';
import { createE2eApp, createTestUser, E2eApp } from './helpers/e2e-app';

/// Réapprovisionnement (P1 n°19, spec §19).
///
/// Éprouvé en priorité : la règle `stock <= seuil` sur le total MAGASIN + DÉPÔT ;
/// une rupture remonte même sans seuil ; la liste est fermée au vendeur ; et
/// surtout l'alerte ne part qu'au FRANCHISSEMENT du seuil, pas à chaque vente.
describe('Réapprovisionnement (e2e)', () => {
  let e2e: E2eApp;
  let prisma: PrismaService;
  let server: E2eApp['server'];

  const suffix = Date.now();
  const PASSWORD = 'MotDePasseTemp1!';
  const userIds: string[] = [];
  const productIds: string[] = [];
  const supplierIds: string[] = [];
  const ids: Record<string, string> = {};
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

  /// Produit avec son stock posé en base, et ses seuils.
  const product = async (opts: {
    quantity: string;
    minThreshold?: string;
    safetyStock?: string;
    locationId?: string;
    supplierId?: string | null;
    lastPurchasePriceHt?: number;
    isActive?: boolean;
  }) => {
    const n = ++counter;
    const created = await prisma.product.create({
      data: {
        sku: `E2E-REA-${suffix}-${n}`,
        barcode: `E2E-REA-BC-${suffix}-${n}`,
        name: `Produit réappro ${n}`,
        minThreshold: opts.minThreshold ?? '0',
        safetyStock: opts.safetyStock ?? '0',
        mainSupplierId:
          opts.supplierId === undefined ? ids.supplier : opts.supplierId,
        lastPurchasePriceHt: opts.lastPurchasePriceHt ?? null,
        isActive: opts.isActive ?? true,
      },
    });
    productIds.push(created.id);
    await prisma.stock.create({
      data: {
        productId: created.id,
        locationId: opts.locationId ?? depotId,
        quantity: opts.quantity,
      },
    });
    return created.id;
  };

  /// La liste, TOUJOURS bornée au fournisseur de ce test : la base e2e est
  /// partagée, et sans ce filtre les produits laissés par les autres suites
  /// repoussent les nôtres hors de la première page — les assertions devenaient
  /// dépendantes de l'ordre d'exécution (relevé par la revue).
  const lines = async (token = tokens.admin, query = '') =>
    (
      await as(token)
        .get(`/api/replenishment?limit=200&supplierId=${ids.supplier}${query}`)
        .expect(200)
    ).body;

  const lineOf = (body: { data: { productId: string }[] }, productId: string) =>
    body.data.find((row) => row.productId === productId);

  /// Mouvement de stock par le JOURNAL, avec un delta signé. Passe par
  /// `applyMovement`, donc par le même chemin que l'alerte : c'est bien le
  /// mouvement qui est éprouvé, pas un contournement.
  ///
  /// Sert pour une ENTRÉE (une perte ne peut pas être négative) et pour une
  /// régularisation sur un produit DÉSACTIVÉ — que la déclaration de perte
  /// refuse, alors que le journal l'autorise (règle 7 : une régularisation ne
  /// doit jamais être bloquée par une désactivation).
  const moveStock = async (productId: string, quantity: string) => {
    const ledger = e2e.app.get(StockLedgerService);
    await prisma.$transaction((tx) =>
      ledger.applyMovement(tx, {
        productId,
        locationId: depotId,
        quantity: new Prisma.Decimal(quantity),
        type: 'AJUSTEMENT_INVENTAIRE',
        operationType: 'MANUAL',
        userId: ids.admin,
      }),
    );
  };

  /// Une perte validée = une SORTIE de stock immédiate : le chemin le plus court
  /// pour faire franchir un seuil dans un test.
  const takeOut = (token: string, productId: string, quantity: string) =>
    as(token).post('/api/stock/losses').send({
      productId,
      locationId: depotId,
      quantity,
      comment: 'Sortie de test',
    });

  const alertsFor = (userId: string, productId: string) =>
    prisma.notification.findMany({
      where: { userId, operationType: 'PRODUCT', operationId: productId },
      select: { type: true, priority: true, title: true, body: true },
    });

  beforeAll(async () => {
    e2e = await createE2eApp();
    prisma = e2e.prisma;
    server = e2e.server;
    depotId = (
      await prisma.location.findFirstOrThrow({ where: { type: 'DEPOT' } })
    ).id;
    magasinId = (
      await prisma.location.findFirstOrThrow({ where: { type: 'MAGASIN' } })
    ).id;

    const supplier = await prisma.supplier.create({
      data: { name: `Fournisseur réappro ${suffix}` },
    });
    supplierIds.push(supplier.id);
    ids.supplier = supplier.id;

    for (const [key, role] of [
      ['admin', RoleCode.ADMIN],
      ['admin2', RoleCode.ADMIN],
      ['vendeur', RoleCode.VENDEUR],
      ['magasinier', RoleCode.MAGASINIER],
    ] as const) {
      const email = `e2e-rea-${key}-${suffix}@test.local`;
      const user = await createTestUser(prisma, {
        email,
        password: PASSWORD,
        roles: [role],
      });
      userIds.push(user.id);
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
    const declarations = await prisma.stockLossDeclaration.findMany({
      where: { productId: { in: productIds } },
      select: { id: true },
    });
    await prisma.notification.deleteMany({
      where: {
        OR: [{ userId: { in: userIds } }, { operationId: { in: productIds } }],
      },
    });
    await prisma.auditLog.deleteMany({
      where: {
        OR: [
          { entityId: { in: declarations.map((d) => d.id) } },
          { userId: { in: userIds } },
        ],
      },
    });
    await prisma.stockLossDeclaration.deleteMany({
      where: { productId: { in: productIds } },
    });
    const transfers = await prisma.transfer.findMany({
      where: { lines: { some: { productId: { in: productIds } } } },
      select: { id: true },
    });
    await prisma.transferLine.deleteMany({
      where: { transferId: { in: transfers.map((t) => t.id) } },
    });
    await prisma.transfer.deleteMany({
      where: { id: { in: transfers.map((t) => t.id) } },
    });
    await prisma.stockMovement.deleteMany({
      where: { productId: { in: productIds } },
    });
    await prisma.stock.deleteMany({ where: { productId: { in: productIds } } });
    await prisma.product.deleteMany({ where: { id: { in: productIds } } });
    await prisma.user.deleteMany({ where: { id: { in: userIds } } });
    await prisma.supplier.deleteMany({ where: { id: { in: supplierIds } } });
    await e2e.app.close();
  });

  describe('la liste', () => {
    it('un produit sous son seuil remonte, avec la quantité proposée', async () => {
      const id = await product({
        quantity: '8.000',
        minThreshold: '20.000',
        supplierId: ids.supplier,
        lastPurchasePriceHt: 15_000,
      });

      const row = lineOf(await lines(), id);
      expect(row).toMatchObject({
        quantity: '8.000',
        minThreshold: '20.000',
        // 2 × 20 − 8 : repasser AU-DESSUS du seuil, sinon l'alerte retombe
        // à la vente suivante.
        suggestedQuantity: '32.000',
        isOutOfStock: false,
        supplierId: ids.supplier,
        // Le coût est rendu à l'unité : l'écran multiplie par la quantité que
        // l'utilisateur a sous les yeux, qu'il peut modifier.
        lastPurchasePriceHt: 15_000,
      });
    });

    it('un produit au-dessus de son seuil ne remonte PAS', async () => {
      const id = await product({ quantity: '50.000', minThreshold: '20.000' });
      expect(lineOf(await lines(), id)).toBeUndefined();
    });

    it('pile SUR le seuil : à racheter (spec §19 : `<=`)', async () => {
      const id = await product({ quantity: '20.000', minThreshold: '20.000' });
      expect(lineOf(await lines(), id)).toBeDefined();
    });

    /// Le catalogue crée tous les produits avec un seuil à 0. Si 0 déclenchait,
    /// la liste serait inutilisable dès le premier jour.
    it('un seuil à 0 ne fait pas remonter un produit qui a du stock', async () => {
      const id = await product({ quantity: '5.000', minThreshold: '0' });
      expect(lineOf(await lines(), id)).toBeUndefined();
    });

    it('une rupture remonte MÊME sans seuil défini', async () => {
      const id = await product({ quantity: '0.000', minThreshold: '0' });
      const row = lineOf(await lines(), id);
      expect(row).toMatchObject({
        isOutOfStock: true,
        suggestedQuantity: '1.000',
      });
    });

    it('le transit ne compte pas : une marchandise en route n’est pas sur l’étagère', async () => {
      const transit = await prisma.location.findFirstOrThrow({
        where: { type: 'TRANSIT' },
      });
      const id = await product({ quantity: '0.000', minThreshold: '20.000' });
      await prisma.stock.create({
        data: { productId: id, locationId: transit.id, quantity: '100.000' },
      });

      // 100 unités en transit ne sauvent pas le produit : il est en rupture.
      expect(lineOf(await lines(), id)).toMatchObject({
        quantity: '0.000',
        isOutOfStock: true,
      });
    });

    it('magasin et dépôt s’additionnent', async () => {
      const id = await product({ quantity: '12.000', minThreshold: '20.000' });
      await prisma.stock.create({
        data: { productId: id, locationId: magasinId, quantity: '30.000' },
      });
      // 12 + 30 = 42 > 20 : plus rien à racheter.
      expect(lineOf(await lines(), id)).toBeUndefined();
    });

    it('un produit désactivé ne remonte pas — on ne le rachète plus', async () => {
      const id = await product({
        quantity: '0.000',
        minThreshold: '20.000',
        isActive: false,
      });
      expect(lineOf(await lines(), id)).toBeUndefined();
    });

    it('les ruptures passent devant, et `outOfStockOnly` les isole', async () => {
      const faible = await product({
        quantity: '19.000',
        minThreshold: '20.000',
      });
      const rupture = await product({
        quantity: '0.000',
        minThreshold: '20.000',
      });

      const body = await lines();
      const positions = body.data.map(
        (r: { productId: string }) => r.productId,
      );
      expect(positions.indexOf(rupture)).toBeLessThan(
        positions.indexOf(faible),
      );
      // Borné au fournisseur du test, donc comptable : les ruptures créées
      // jusqu'ici par cette suite, celle-ci comprise.
      expect(body.outOfStockCount).toBe(
        body.data.filter((r: { isOutOfStock: boolean }) => r.isOutOfStock)
          .length,
      );

      const seulesRuptures = await lines(tokens.admin, '&outOfStockOnly=true');
      expect(lineOf(seulesRuptures, rupture)).toBeDefined();
      expect(lineOf(seulesRuptures, faible)).toBeUndefined();
    });

    it('filtre par fournisseur principal', async () => {
      const chezLui = await product({
        quantity: '1.000',
        minThreshold: '20.000',
        supplierId: ids.supplier,
      });
      const ailleurs = await product({
        quantity: '1.000',
        minThreshold: '20.000',
        supplierId: null,
      });

      const body = await lines();
      expect(lineOf(body, chezLui)).toBeDefined();
      expect(lineOf(body, ailleurs)).toBeUndefined();

      // Et sans filtre, celui « d'ailleurs » est bien là : c'est le filtre qui
      // l'écarte, pas la règle.
      const sansFiltre = (
        await as(tokens.admin).get('/api/replenishment?limit=200').expect(200)
      ).body;
      expect(lineOf(sansFiltre, ailleurs)).toBeDefined();
    });

    it('sans dernier prix d’achat, le coût vaut null (pas 0)', async () => {
      const id = await product({ quantity: '1.000', minThreshold: '20.000' });
      expect(lineOf(await lines(), id)).toMatchObject({
        lastPurchasePriceHt: null,
      });
    });

    /// Sans cette garde, un catalogue importé remonte ENTIER en tête de liste,
    /// en urgence maximale, dès l'installation.
    it('un produit qui n’a JAMAIS eu de stock ne remonte pas', async () => {
      const jamais = await prisma.product.create({
        data: {
          sku: `E2E-REA-${suffix}-jamais`,
          barcode: `E2E-REA-BC-${suffix}-jamais`,
          name: 'Produit jamais entré en stock',
          minThreshold: '20.000',
          mainSupplierId: ids.supplier,
        },
      });
      productIds.push(jamais.id);

      expect(lineOf(await lines(), jamais.id)).toBeUndefined();
    });

    it('le même produit remonte dès qu’il a eu du stock, même épuisé', async () => {
      const id = await product({ quantity: '0.000', minThreshold: '20.000' });
      expect(lineOf(await lines(), id)).toMatchObject({ isOutOfStock: true });
    });
  });

  describe('qui y a droit', () => {
    it('le magasinier oui (il commande), le vendeur non', async () => {
      await as(tokens.magasinier).get('/api/replenishment').expect(200);
      await as(tokens.vendeur).get('/api/replenishment').expect(403);
    });

    it('sans token : refusé', async () => {
      await request(server).get('/api/replenishment').expect(401);
    });
  });

  describe('alertes de stock (spec §19)', () => {
    it('franchir le seuil prévient l’admin et le magasinier, pas l’auteur', async () => {
      const id = await product({ quantity: '25.000', minThreshold: '20.000' });

      // 25 → 19 : le seuil est franchi.
      await takeOut(tokens.admin, id, '6.000').expect(201);

      const pourLAutreAdmin = await alertsFor(ids.admin2, id);
      expect(pourLAutreAdmin).toHaveLength(1);
      expect(pourLAutreAdmin[0]).toMatchObject({
        type: 'STOCK_FAIBLE',
        priority: 'HAUTE',
      });
      expect(pourLAutreAdmin[0].title).toContain('Stock faible');
      expect(pourLAutreAdmin[0].body).toContain('19.000');
      expect(await alertsFor(ids.magasinier, id)).toHaveLength(1);
      // L'auteur du mouvement le sait déjà.
      expect(await alertsFor(ids.admin, id)).toHaveLength(0);
      // Le vendeur ne peut rien y faire : il n'est pas prévenu.
      expect(await alertsFor(ids.vendeur, id)).toHaveLength(0);
    });

    /// LE point de cette feature : sans la garde de franchissement, chaque vente
    /// d'un produit déjà sous son seuil réécrit la même alerte et enterre les
    /// autres.
    it('rester sous le seuil ne réécrit PAS l’alerte', async () => {
      const id = await product({ quantity: '25.000', minThreshold: '20.000' });

      await takeOut(tokens.admin, id, '6.000').expect(201); // 25 → 19 : franchit
      await takeOut(tokens.admin, id, '2.000').expect(201); // 19 → 17 : déjà sous
      await takeOut(tokens.admin, id, '2.000').expect(201); // 17 → 15 : déjà sous

      expect(await alertsFor(ids.magasinier, id)).toHaveLength(1);
    });

    it('tomber à zéro donne une RUPTURE urgente, pas un stock faible', async () => {
      const id = await product({ quantity: '25.000', minThreshold: '20.000' });

      await takeOut(tokens.admin, id, '6.000').expect(201); // franchit le seuil
      await takeOut(tokens.admin, id, '19.000').expect(201); // 19 → 0 : rupture

      const alertes = await alertsFor(ids.magasinier, id);
      expect(alertes.map((a) => a.type)).toEqual(['STOCK_FAIBLE', 'RUPTURE']);
      expect(alertes[1].priority).toBe('URGENTE');
    });

    /// Une perte NE PEUT PAS être négative (le DTO exige du positif) : la
    /// première version de ce test envoyait `-3.000`, recevait un 400 qu'elle
    /// n'assertait pas, et passait donc À VIDE. L'entrée se fait par le
    /// journal, comme une réception le ferait.
    it('une ENTRÉE de stock n’alerte jamais', async () => {
      const id = await product({ quantity: '5.000', minThreshold: '20.000' });

      // Déjà sous le seuil, mais on AJOUTE : rien ne doit partir.
      await moveStock(id, '3.000');

      expect(await alertsFor(ids.magasinier, id)).toHaveLength(0);
      // Et le refus de la perte négative est bien la règle, pas un hasard.
      await takeOut(tokens.admin, id, '-3.000').expect(422);
    });

    /// Trouvé par l'audit sécurité du 2026-09-25 : le premier mouvement d'une
    /// expédition est une SORTIE du dépôt (le transit ne reçoit que le second),
    /// donc le total baissait vraiment et une fausse « RUPTURE URGENTE » partait
    /// à chaque expédition. Un transfert déplace, il ne change pas ce qu'il faut
    /// RACHETER.
    it('expédier un transfert n’alerte PAS — ça déplace, ça n’achète pas', async () => {
      const id = await product({ quantity: '25.000', minThreshold: '20.000' });

      const demande = (
        await as(tokens.vendeur)
          .post('/api/transfers')
          .send({
            clientMutationId: randomUUID(),
            fromLocationId: depotId,
            toLocationId: magasinId,
            lines: [{ productId: id, quantity: '25.000' }],
          })
          .expect(201)
      ).body;

      await as(tokens.magasinier)
        .post(`/api/transfers/${demande.id}/accept`)
        .expect(200);
      await as(tokens.magasinier)
        .post(`/api/transfers/${demande.id}/prepare`)
        .send({ lines: [{ productId: id, preparedQuantity: '25.000' }] })
        .expect(200);
      // Tout le stock du dépôt part : le total MAGASIN + DÉPÔT tombe à zéro le
      // temps du trajet, puisque le transit ne compte pas.
      await as(tokens.magasinier)
        .post(`/api/transfers/${demande.id}/ship`)
        .expect(200);

      expect(await alertsFor(ids.magasinier, id)).toHaveLength(0);
      expect(await alertsFor(ids.admin2, id)).toHaveLength(0);
    });

    it('un produit désactivé n’alerte pas — il n’est pas dans la liste', async () => {
      const id = await product({
        quantity: '25.000',
        minThreshold: '20.000',
        isActive: false,
      });

      // La DÉCLARATION de perte est refusée sur un produit inactif ; le JOURNAL,
      // lui, autorise une régularisation (règle 7 — un stock résiduel doit
      // pouvoir être soldé). C'est donc par là que le cas arrive vraiment.
      await takeOut(tokens.admin, id, '6.000').expect(422);
      await moveStock(id, '-6.000'); // 25 -> 19 : franchit le seuil

      expect(await alertsFor(ids.magasinier, id)).toHaveLength(0);
    });

    /// Le franchissement se réarme dès que le stock repasse au-dessus du seuil :
    /// sans déduplication, une boucle sortie -> correction -> sortie produisait
    /// une alerte par tour et enterrait les autres.
    it('une alerte NON LUE n’est pas réécrite au franchissement suivant', async () => {
      const id = await product({ quantity: '25.000', minThreshold: '20.000' });

      await takeOut(tokens.admin, id, '6.000').expect(201); // 25 -> 19 : alerte
      expect(await alertsFor(ids.magasinier, id)).toHaveLength(1);

      // Retour au-dessus du seuil (entrée : n'alerte jamais), puis on refranchit.
      await moveStock(id, '10.000'); // 19 -> 29
      await takeOut(tokens.admin, id, '10.000').expect(201); // 29 -> 19 : refranchit

      // Toujours UNE seule alerte : la première n'a pas été lue.
      expect(await alertsFor(ids.magasinier, id)).toHaveLength(1);
    });

    it('après lecture, un nouveau franchissement alerte de nouveau', async () => {
      const id = await product({ quantity: '25.000', minThreshold: '20.000' });

      await takeOut(tokens.admin, id, '6.000').expect(201);
      await prisma.notification.updateMany({
        where: { operationId: id },
        data: { isRead: true, readAt: new Date() },
      });

      await moveStock(id, '10.000');
      await takeOut(tokens.admin, id, '10.000').expect(201);

      expect(await alertsFor(ids.magasinier, id)).toHaveLength(2);
    });

    it('un produit sans seuil n’alerte qu’à la rupture', async () => {
      const id = await product({ quantity: '10.000', minThreshold: '0' });

      await takeOut(tokens.admin, id, '4.000').expect(201); // 10 → 6 : rien
      expect(await alertsFor(ids.magasinier, id)).toHaveLength(0);

      await takeOut(tokens.admin, id, '6.000').expect(201); // 6 → 0 : rupture
      expect((await alertsFor(ids.magasinier, id)).map((a) => a.type)).toEqual([
        'RUPTURE',
      ]);
    });
  });
});
