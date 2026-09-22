import { INestApplication } from '@nestjs/common';
import { randomUUID } from 'node:crypto';
import * as request from 'supertest';
import { hashPassword } from '../src/auth/password';
import { RoleCode } from '../src/common/auth.decorators';
import { PrismaService } from '../src/prisma/prisma.service';
import { Prisma } from '../src/generated/prisma/client';
import { StockLedgerService } from '../src/stock/stock-ledger.service';
import { createE2eApp } from './helpers/e2e-app';
import { authorOf } from './helpers/sync-author';

/// Contrat de synchronisation offline (docs/context.md §3-§5) vérifié de bout en bout
/// sur la VRAIE base : idempotence, anti-stock-négatif, absence d'effet de bord.
describe('Sync (e2e)', () => {
  let app: INestApplication;
  let prisma: PrismaService;
  let server: ReturnType<INestApplication['getHttpServer']>;

  const suffix = Date.now();
  const PASSWORD = 'MotDePasseTest1!';
  /// ADMIN : ses pertes s'appliquent tout de suite — c'est lui qui exerce le moteur.
  const adminEmail = `e2e-sync-admin-${suffix}@test.local`;
  /// MAGASINIER : sa perte hors-ligne reste EN ATTENTE de validation (décision 2026-09-14).
  const magasinierEmail = `e2e-sync-magasinier-${suffix}@test.local`;
  const vendeurEmail = `e2e-sync-vendeur-${suffix}@test.local`;
  /// Vendeur à qui l'admin a accordé `stock.loss` « à la carte » : a la permission,
  /// pas le rôle. En ligne, `POST /stock/losses` le refuse — le sync doit faire pareil.
  const vendeurPlusEmail = `e2e-sync-vendeur-plus-${suffix}@test.local`;
  const DEVICE = 'e2e-mobile-magasinier';

  let adminToken: string;
  let magasinierToken: string;
  let vendeurToken: string;
  let vendeurPlusToken: string;
  let locationId: string;
  /// Produit principal : 10.000 en stock au départ.
  let productId: string;
  /// Produit autorisé à passer en négatif (`allowBackorder`).
  let backorderProductId: string;
  /// Produit dédié au test d'ordre du lot : 7.000 en stock.
  let orderedProductId: string;
  /// Produit dédié au test d'auteur du lot (N6b) : n'entame pas celui des autres.
  let authorProductId: string;
  /// Produit sur-réservé (0 en stock, 5 réservés) : disponible NÉGATIF au départ.
  let overReservedProductId: string;
  let ledger: StockLedgerService;

  /// Enveloppe de mutation — une perte/casse saisie hors-ligne.
  const lossMutation = (over: Record<string, unknown> = {}) => ({
    clientMutationId: randomUUID(),
    deviceId: DEVICE,
    operationType: 'MANUAL',
    deviceTimestamp: new Date('2026-09-09T08:00:00.000Z').toISOString(),
    ...over,
    payload: {
      productId,
      locationId,
      quantity: '3.000',
      type: 'PERTE_CASSE',
      ...((over.payload as Record<string, unknown>) ?? {}),
    },
  });

  const sync = (token: string, mutations: unknown[]) =>
    request(server)
      .post('/api/sync')
      .set('Authorization', `Bearer ${token}`)
      .send({ authorUserId: authorOf(token), mutations });

  const stockOf = async (id: string): Promise<string> => {
    const stock = await prisma.stock.findFirst({
      where: { productId: id, locationId },
      select: { quantity: true },
    });
    return stock ? stock.quantity.toFixed(3) : 'absent';
  };

  const movementCount = (id: string) =>
    prisma.stockMovement.count({ where: { productId: id } });

  beforeAll(async () => {
    ({ app, prisma, server } = await createE2eApp());
    ledger = app.get(StockLedgerService);

    const passwordHash = await hashPassword(PASSWORD);
    for (const [email, role] of [
      [adminEmail, RoleCode.ADMIN],
      [magasinierEmail, RoleCode.MAGASINIER],
      [vendeurEmail, RoleCode.VENDEUR],
    ] as const) {
      await prisma.user.create({
        data: {
          email,
          fullName: `E2E sync ${role}`,
          passwordHash,
          mustChangePassword: false,
          roles: { connect: { code: role } },
        },
      });
    }
    await prisma.user.create({
      data: {
        email: vendeurPlusEmail,
        fullName: 'E2E sync VENDEUR + stock.loss',
        passwordHash,
        mustChangePassword: false,
        roles: { connect: { code: RoleCode.VENDEUR } },
        permissions: { connect: { code: 'stock.loss' } },
      },
    });

    const login = async (email: string): Promise<string> => {
      const res = await request(server)
        .post('/api/auth/login')
        .send({ identifier: email, password: PASSWORD });
      return res.body.accessToken;
    };
    adminToken = await login(adminEmail);
    magasinierToken = await login(magasinierEmail);
    vendeurToken = await login(vendeurEmail);
    vendeurPlusToken = await login(vendeurPlusEmail);

    const location = await prisma.location.create({
      data: { code: `E2E-DEPOT-${suffix}`, name: 'Dépôt e2e', type: 'DEPOT' },
    });
    locationId = location.id;

    // Fixtures : le stock initial est posé directement en base (donnée de départ),
    // les tests vérifient que SEUL le moteur de sync le fait ensuite bouger.
    const makeProduct = async (
      label: string,
      quantity: string,
      allowBackorder = false,
      reservedQuantity = '0.000',
    ): Promise<string> => {
      const product = await prisma.product.create({
        data: {
          sku: `E2E-${label}-${suffix}`,
          barcode: `E2E-BC-${label}-${suffix}`,
          name: `Câble e2e ${label}`,
          allowBackorder,
        },
      });
      await prisma.stock.create({
        data: { productId: product.id, locationId, quantity, reservedQuantity },
      });
      return product.id;
    };
    productId = await makeProduct('A', '10.000');
    backorderProductId = await makeProduct('B', '0.000', true);
    orderedProductId = await makeProduct('C', '7.000');
    overReservedProductId = await makeProduct('D', '0.000', false, '5.000');
    authorProductId = await makeProduct('E', '10.000');
  });

  afterAll(async () => {
    const productIds = [
      productId,
      backorderProductId,
      orderedProductId,
      overReservedProductId,
      authorProductId,
    ];
    const users = await prisma.user.findMany({
      where: {
        email: {
          in: [adminEmail, magasinierEmail, vendeurEmail, vendeurPlusEmail],
        },
      },
      select: { id: true },
    });
    const userIds = users.map((user) => user.id);

    await prisma.stockMovement.deleteMany({
      where: { productId: { in: productIds } },
    });
    await prisma.stockLossDeclaration.deleteMany({
      where: { productId: { in: productIds } },
    });
    await prisma.auditLog.deleteMany({ where: { userId: { in: userIds } } });
    await prisma.syncMutation.deleteMany({
      where: { userId: { in: userIds } },
    });
    await prisma.stock.deleteMany({ where: { productId: { in: productIds } } });
    await prisma.product.deleteMany({ where: { id: { in: productIds } } });
    await prisma.location.delete({ where: { id: locationId } });
    await prisma.user.deleteMany({ where: { id: { in: userIds } } });
    await app.close();
  });

  it('refuse la synchronisation sans token', async () => {
    const res = await request(server).post('/api/sync').send({ mutations: [] });

    expect(res.status).toBe(401);
    expect(res.body.code).toBe('ACCESS_TOKEN_MISSING');
  });

  it('applique une perte saisie hors-ligne : mouvement + projection', async () => {
    const res = await sync(adminToken, [lossMutation()]);

    expect(res.status).toBe(200);
    expect(res.body.results[0]).toMatchObject({
      status: 'CONFIRMEE',
      alreadyProcessed: false,
      serverState: { quantityAfter: '7.000', availableAfter: '7.000' },
    });

    // L'entité est la DÉCLARATION ; le mouvement la référence (operationId).
    const movement = await prisma.stockMovement.findFirst({
      where: { operationId: res.body.results[0].entityId },
    });
    expect(movement?.quantity.toFixed(3)).toBe('-3.000');
    expect(movement?.type).toBe('PERTE_CASSE');
    expect(await stockOf(productId)).toBe('7.000');

    // Contrat §4.4 : l'audit est écrit dans la même transaction que le mouvement.
    const audit = await prisma.auditLog.findFirst({
      where: {
        entityId: res.body.results[0].entityId,
        entityType: 'StockLossDeclaration',
      },
    });
    expect(audit?.action).toBe('CREATE');
  });

  it('lot déclaré par un AUTRE compte : rien appliqué, rien mémorisé (N6b)', async () => {
    // Poste partagé : les opérations de l'admin ne partent JAMAIS avec la
    // session du magasinier — elles lui seraient attribuées.
    const before = await stockOf(authorProductId);
    const mutation = lossMutation({ payload: { productId: authorProductId } });
    const res = await request(server)
      .post('/api/sync')
      .set('Authorization', `Bearer ${magasinierToken}`)
      .send({ authorUserId: authorOf(adminToken), mutations: [mutation] })
      .expect(200);
    expect(res.body.results[0]).toMatchObject({
      status: 'NON_TRAITEE',
      code: 'SYNC_AUTHOR_MISMATCH',
    });
    expect(await stockOf(authorProductId)).toBe(before);
    expect(
      await prisma.syncMutation.count({
        where: { clientMutationId: mutation.clientMutationId },
      }),
    ).toBe(0);

    // Renvoyée avec la bonne session, elle passe normalement.
    const ok = await sync(adminToken, [mutation]);
    expect(ok.body.results[0].status).toBe('CONFIRMEE');
  });

  it.each([
    ['absent', {}],
    ['qui n’est pas un UUID', { authorUserId: 'admin' }],
  ])('auteur du lot %s → 400, rien traité', async (_label, author) => {
    const mutation = lossMutation({ payload: { productId: authorProductId } });
    const res = await request(server)
      .post('/api/sync')
      .set('Authorization', `Bearer ${adminToken}`)
      .send({ ...author, mutations: [mutation] })
      .expect(400);
    expect(res.body.code).toBe('VALIDATION_FAILED');
    expect(
      await prisma.syncMutation.count({
        where: { clientMutationId: mutation.clientMutationId },
      }),
    ).toBe(0);
  });

  it('la perte hors-ligne du MAGASINIER reste EN ATTENTE : le stock ne bouge pas', async () => {
    const stockBefore = await stockOf(productId);
    const movementsBefore = await movementCount(productId);

    const res = await sync(magasinierToken, [
      lossMutation({ payload: { quantity: '1.000' } }),
    ]);

    expect(res.body.results[0]).toMatchObject({
      status: 'CONFIRMEE',
      serverState: { status: 'EN_ATTENTE' },
    });
    const declaration = await prisma.stockLossDeclaration.findUnique({
      where: { id: res.body.results[0].entityId },
    });
    expect(declaration?.status).toBe('EN_ATTENTE');
    expect(declaration?.movementId).toBeNull();
    expect(await stockOf(productId)).toBe(stockBefore);
    expect(await movementCount(productId)).toBe(movementsBefore);
  });

  it('ne réapplique JAMAIS une mutation renvoyée (idempotence)', async () => {
    const mutation = lossMutation({ payload: { quantity: '2.000' } });

    const first = await sync(adminToken, [mutation]);
    const stockAfterFirst = await stockOf(productId);
    const movementsAfterFirst = await movementCount(productId);

    // Reconnexion instable : le client renvoie exactement la même mutation.
    const second = await sync(adminToken, [mutation]);

    expect(first.body.results[0].status).toBe('CONFIRMEE');
    expect(second.body.results[0]).toMatchObject({
      status: 'CONFIRMEE',
      alreadyProcessed: true,
      entityId: first.body.results[0].entityId,
    });
    expect(await stockOf(productId)).toBe(stockAfterFirst);
    expect(await movementCount(productId)).toBe(movementsAfterFirst);
  });

  it('n’applique qu’une fois deux envois CONCURRENTS de la même mutation', async () => {
    // Retry pendant que la première requête est encore en vol : c'est l'unicité de
    // `clientMutationId`, tenue par la base, qui sérialise les deux.
    const mutation = lossMutation({ payload: { quantity: '1.000' } });
    const movementsBefore = await movementCount(productId);

    const [first, second] = await Promise.all([
      sync(adminToken, [mutation]),
      sync(adminToken, [mutation]),
    ]);

    const statuses = [first.body.results[0], second.body.results[0]];
    expect(statuses.every((r) => r.status === 'CONFIRMEE')).toBe(true);
    // Les deux réponses désignent le MÊME mouvement, et un seul a été créé.
    expect(statuses[0].entityId).toBe(statuses[1].entityId);
    expect(statuses.filter((r) => r.alreadyProcessed)).toHaveLength(1);
    expect(await movementCount(productId)).toBe(movementsBefore + 1);
  });

  it('rejette une mutation qui rendrait le stock négatif, SANS effet de bord', async () => {
    const stockBefore = await stockOf(productId);
    const movementsBefore = await movementCount(productId);

    const res = await sync(adminToken, [
      lossMutation({ payload: { quantity: '999.000' } }),
    ]);

    expect(res.body.results[0]).toMatchObject({
      status: 'REJETEE',
      code: 'STOCK_NEGATIVE',
      alreadyProcessed: false,
    });
    expect(res.body.results[0].reason).toContain('disponible');
    // Rien n'a bougé : ni la projection, ni le journal.
    expect(await stockOf(productId)).toBe(stockBefore);
    expect(await movementCount(productId)).toBe(movementsBefore);
  });

  it('mémorise le rejet : le renvoi donne le même verdict, sans retraitement', async () => {
    const mutation = lossMutation({ payload: { quantity: '999.000' } });

    const first = await sync(adminToken, [mutation]);
    const second = await sync(adminToken, [mutation]);

    expect(first.body.results[0].alreadyProcessed).toBe(false);
    expect(second.body.results[0]).toMatchObject({
      status: 'REJETEE',
      code: 'STOCK_NEGATIVE',
      alreadyProcessed: true,
    });
  });

  it('autorise le négatif sur un produit en backorder', async () => {
    const res = await sync(adminToken, [
      lossMutation({
        payload: { productId: backorderProductId, quantity: '2.000' },
      }),
    ]);

    expect(res.body.results[0].status).toBe('CONFIRMEE');
    expect(await stockOf(backorderProductId)).toBe('-2.000');
  });

  it('rejette la perte déclarée par un vendeur : la matrice vaut aussi hors-ligne', async () => {
    const movementsBefore = await movementCount(productId);

    const res = await sync(vendeurToken, [lossMutation()]);

    // Le rôle est contrôlé avant la permission, comme dans `RolesGuard` en ligne.
    expect(res.body.results[0]).toMatchObject({
      status: 'REJETEE',
      code: 'FORBIDDEN_ROLE',
    });
    expect(await movementCount(productId)).toBe(movementsBefore);
  });

  it('rejette un payload non conforme au contrat', async () => {
    const res = await sync(adminToken, [
      lossMutation({ payload: { quantity: 'beaucoup' } }),
    ]);

    expect(res.body.results[0]).toMatchObject({
      status: 'REJETEE',
      code: 'VALIDATION_FAILED',
    });
  });

  it('garde en file une opération dont la feature n’est pas encore livrée', async () => {
    const mutation = {
      clientMutationId: randomUUID(),
      deviceId: DEVICE,
      // Une commande fournisseur reste un geste EN LIGNE : jamais de handler.
      operationType: 'PURCHASE_ORDER',
      payload: { total: 1000 },
      deviceTimestamp: new Date('2026-09-09T08:00:00.000Z').toISOString(),
    };

    const res = await sync(adminToken, [mutation]);

    expect(res.body.results[0]).toMatchObject({
      status: 'NON_TRAITEE',
      code: 'NOT_IMPLEMENTED',
    });
    // Rien de mémorisé : la mutation reste valide si un handler arrive dans une version ultérieure.
    const memorized = await prisma.syncMutation.findUnique({
      where: { clientMutationId: mutation.clientMutationId },
    });
    expect(memorized).toBeNull();
  });

  it('applique le lot dans l’ordre du timestamp appareil, pas celui d’envoi', async () => {
    // Stock 7 : la perte de 6 (la plus ANCIENNE) passe, celle de 2 est ensuite rejetée.
    // Envoyées dans l'ordre inverse — un traitement dans l'ordre du tableau donnerait
    // le verdict opposé.
    const older = lossMutation({
      deviceTimestamp: new Date('2026-09-09T09:00:01.000Z').toISOString(),
      payload: { productId: orderedProductId, quantity: '6.000' },
    });
    const newer = lossMutation({
      deviceTimestamp: new Date('2026-09-09T09:00:02.000Z').toISOString(),
      payload: { productId: orderedProductId, quantity: '2.000' },
    });

    const res = await sync(adminToken, [newer, older]);
    const byId = Object.fromEntries(
      res.body.results.map((r: { clientMutationId: string }) => [
        r.clientMutationId,
        r,
      ]),
    );

    expect(byId[older.clientMutationId].status).toBe('CONFIRMEE');
    expect(byId[newer.clientMutationId]).toMatchObject({
      status: 'REJETEE',
      code: 'STOCK_NEGATIVE',
    });
    expect(await stockOf(orderedProductId)).toBe('1.000');
  });

  it('refuse le vendeur À QUI la permission a été accordée : le rôle manque toujours', async () => {
    const movementsBefore = await movementCount(productId);

    const res = await sync(vendeurPlusToken, [lossMutation()]);

    // Le token porte bien `stock.loss` — c'est le rôle qui ferme la porte, exactement
    // comme `POST /stock/losses` en ligne. Le sync n'est pas une porte dérobée.
    expect(res.body.results[0]).toMatchObject({
      status: 'REJETEE',
      code: 'FORBIDDEN_ROLE',
    });
    expect(await movementCount(productId)).toBe(movementsBefore);
  });

  it('rejette DÉFINITIVEMENT un id de déclaration déjà pris, sans geler la file', async () => {
    const movementId = randomUUID();
    const premiere = lossMutation({
      payload: { id: movementId, quantity: '1.000' },
    });
    expect((await sync(adminToken, [premiere])).body.results[0].status).toBe(
      'CONFIRMEE',
    );

    // Nouvelle mutation, mais qui réutilise l'id du mouvement déjà créé.
    const doublon = lossMutation({
      deviceTimestamp: new Date('2026-09-09T10:00:01.000Z').toISOString(),
      payload: { id: movementId, quantity: '1.000' },
    });
    const suivante = lossMutation({
      deviceTimestamp: new Date('2026-09-09T10:00:02.000Z').toISOString(),
      payload: { quantity: '1.000' },
    });

    const res = await sync(adminToken, [doublon, suivante]);

    expect(res.body.results[0]).toMatchObject({
      status: 'REJETEE',
      code: 'CONFLICT',
    });
    // Le lot continue : un rejet définitif ne bloque pas la file de l'appareil.
    expect(res.body.results[1].status).toBe('CONFIRMEE');
  });

  it('ne renvoie pas à un autre compte le résultat mémorisé d’un collègue', async () => {
    const mutation = lossMutation({ payload: { quantity: '1.000' } });
    expect((await sync(adminToken, [mutation])).body.results[0].status).toBe(
      'CONFIRMEE',
    );

    const res = await sync(vendeurToken, [mutation]);

    expect(res.body.results[0]).toMatchObject({
      status: 'REJETEE',
      code: 'CONFLICT',
      alreadyProcessed: false,
    });
    expect(res.body.results[0].entityId).toBeUndefined();
  });

  /// Le noyau appelé par le sync ET, plus tard, par toutes les opérations en ligne.
  describe('StockLedgerService (socle partagé)', () => {
    const apply = (input: Parameters<StockLedgerService['applyMovement']>[1]) =>
      prisma.$transaction((tx) => ledger.applyMovement(tx, input));

    it('n’empêche JAMAIS une entrée, même si le disponible est déjà négatif', async () => {
      // Disponible de départ : 0 − 5 réservés = −5. Une entrée régularise, elle ne dégrade pas.
      const applied = await apply({
        productId: overReservedProductId,
        locationId,
        quantity: new Prisma.Decimal('4.000'),
        type: 'RETOUR_CLIENT',
        operationType: 'MANUAL',
      });

      expect(applied.quantityAfter).toBe('4.000');
      expect(applied.availableAfter).toBe('-1.000');
    });

    it('refuse la sortie qui creuse un disponible déjà négatif', async () => {
      await expect(
        apply({
          productId: overReservedProductId,
          locationId,
          quantity: new Prisma.Decimal('-1.000'),
          type: 'PERTE_CASSE',
          operationType: 'MANUAL',
        }),
      ).rejects.toMatchObject({ response: { code: 'STOCK_NEGATIVE' } });
    });

    it('refuse un mouvement de quantité nulle', async () => {
      await expect(
        apply({
          productId,
          locationId,
          quantity: new Prisma.Decimal(0),
          type: 'PERTE_CASSE',
          operationType: 'MANUAL',
        }),
      ).rejects.toMatchObject({ response: { code: 'VALIDATION_FAILED' } });
    });
  });
});
