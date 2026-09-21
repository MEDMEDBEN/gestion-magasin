import { randomUUID } from 'crypto';
import * as request from 'supertest';
import { RoleCode } from '../src/common/auth.decorators';
import { PrismaService } from '../src/prisma/prisma.service';
import { createE2eApp, createTestUser, E2eApp } from './helpers/e2e-app';

/// Inventaire (P0 n°9, spec §22) : « comparer théorique ↔ physique ».
///
/// Priorités éprouvées ici : le stock NE BOUGE QU'À LA VALIDATION, l'ajustement
/// est un DELTA (règle 2), la validation est réservée à l'ADMIN (spec §22), et
/// un comptage PÉRIMÉ ne peut pas écraser un mouvement survenu depuis.
describe('Inventaire (e2e)', () => {
  let e2e: E2eApp;
  let prisma: PrismaService;
  let server: E2eApp['server'];

  const suffix = Date.now();
  const PASSWORD = 'MotDePasseTemp1!';
  const userIds: string[] = [];
  const productIds: string[] = [];
  const inventoryIds: string[] = [];
  const tokens: Record<string, string> = {};
  let depotId = '';
  let magasinId = '';
  let transitId = '';
  let counter = 0;

  const as = (token: string) => ({
    get: (url: string) =>
      request(server).get(url).set('Authorization', `Bearer ${token}`),
    post: (url: string) =>
      request(server).post(url).set('Authorization', `Bearer ${token}`),
  });

  /// Produit avec `quantity` unités au dépôt, entrées par le journal.
  const productWithStock = async (quantity = '50') => {
    const n = ++counter;
    const created = (
      await as(tokens.admin)
        .post('/api/products')
        .send({
          sku: `E2E-INV-${suffix}-${n}`,
          name: `Produit inventaire ${n}`,
          unit: 'PIECE',
          initialStock: [{ locationId: depotId, quantity }],
        })
        .expect(201)
    ).body;
    productIds.push(created.id);
    return created.id as string;
  };

  const stockAt = async (productId: string, locationId: string) =>
    (
      await prisma.stock.findFirst({ where: { productId, locationId } })
    )?.quantity.toFixed(3) ?? '0.000';

  /// Inventaire TOURNANT sur un seul produit neuf, prêt à compter.
  const tournant = async (stock = '50') => {
    const productId = await productWithStock(stock);
    const inventory = (
      await as(tokens.magasinier)
        .post('/api/inventories')
        .send({
          clientMutationId: randomUUID(),
          locationId: depotId,
          type: 'TOURNANT',
          zone: 'Zone A',
          productIds: [productId],
        })
        .expect(201)
    ).body;
    inventoryIds.push(inventory.id);
    return { id: inventory.id as string, productId, body: inventory };
  };

  /// Comptage clos à `counted` : l'inventaire est TERMINE, prêt à valider.
  const counted = async (count: string, stock = '50') => {
    const inv = await tournant(stock);
    const body = (
      await as(tokens.magasinier)
        .post(`/api/inventories/${inv.id}/count`)
        .send({
          done: true,
          lines: [{ productId: inv.productId, countedQuantity: count }],
        })
        .expect(200)
    ).body;
    return { ...inv, body };
  };

  beforeAll(async () => {
    e2e = await createE2eApp();
    prisma = e2e.prisma;
    server = e2e.server;
    for (const [key, role] of [
      ['admin', RoleCode.ADMIN],
      ['magasinier', RoleCode.MAGASINIER],
      ['vendeur', RoleCode.VENDEUR],
    ] as const) {
      const email = `e2e-inventaire-${key}-${suffix}@test.local`;
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
    depotId = (
      await prisma.location.findFirstOrThrow({ where: { type: 'DEPOT' } })
    ).id;
    magasinId = (
      await prisma.location.findFirstOrThrow({ where: { type: 'MAGASIN' } })
    ).id;
    transitId = (
      await prisma.location.findFirstOrThrow({ where: { type: 'TRANSIT' } })
    ).id;
  });

  afterAll(async () => {
    await prisma.auditLog.deleteMany({ where: { userId: { in: userIds } } });
    await prisma.inventoryLine.deleteMany({
      where: { inventoryId: { in: inventoryIds } },
    });
    await prisma.inventory.deleteMany({ where: { id: { in: inventoryIds } } });
    await prisma.stockMovement.deleteMany({
      where: { productId: { in: productIds } },
    });
    await prisma.stock.deleteMany({ where: { productId: { in: productIds } } });
    await prisma.product.deleteMany({ where: { id: { in: productIds } } });
    await prisma.user.deleteMany({ where: { id: { in: userIds } } });
    await e2e.app.close();
  });

  it('manque constaté : rien ne bouge avant la validation de l’admin', async () => {
    const inv = await tournant('50');
    expect(inv.body.number).toMatch(/^INV-\d{4}-\d{5}$/);
    expect(inv.body.status).toBe('EN_COURS');
    expect(inv.body.lines[0]).toMatchObject({
      theoreticalQuantity: '50.000',
      countedQuantity: null,
      state: 'CONFORME',
    });

    // Comptage : 47,5 trouvés pour 50 attendus → écart −2,5.
    const afterCount = (
      await as(tokens.magasinier)
        .post(`/api/inventories/${inv.id}/count`)
        .send({
          done: true,
          lines: [{ productId: inv.productId, countedQuantity: '47.5' }],
        })
        .expect(200)
    ).body;
    expect(afterCount.status).toBe('TERMINE');
    expect(afterCount.lines[0]).toMatchObject({
      theoreticalQuantity: '50.000',
      countedQuantity: '47.500',
      difference: '-2.500',
      state: 'ECART',
    });
    // Le comptage ne touche RIEN : c'est la règle de la spec §22.
    expect(await stockAt(inv.productId, depotId)).toBe('50.000');
    expect(
      await prisma.stockMovement.count({
        where: { productId: inv.productId, operationType: 'INVENTORY' },
      }),
    ).toBe(0);

    const validated = (
      await as(tokens.admin)
        .post(`/api/inventories/${inv.id}/validate`)
        .expect(200)
    ).body;
    expect(validated.validatedAt).not.toBeNull();
    expect(await stockAt(inv.productId, depotId)).toBe('47.500');

    // Règle 2 : le stock est corrigé par un MOUVEMENT en delta, pas réécrit.
    const movement = await prisma.stockMovement.findFirstOrThrow({
      where: { productId: inv.productId, operationType: 'INVENTORY' },
    });
    expect(movement.type).toBe('AJUSTEMENT_INVENTAIRE');
    expect(movement.quantity.toFixed(3)).toBe('-2.500');
    expect(movement.operationId).toBe(inv.id);
  });

  it('surplus constaté : l’ajustement ajoute, et une ligne conforme ne bouge rien', async () => {
    const inv = await tournant('50');
    await as(tokens.magasinier)
      .post(`/api/inventories/${inv.id}/count`)
      .send({
        done: true,
        lines: [{ productId: inv.productId, countedQuantity: '53' }],
      })
      .expect(200);
    await as(tokens.admin)
      .post(`/api/inventories/${inv.id}/validate`)
      .expect(200);
    expect(await stockAt(inv.productId, depotId)).toBe('53.000');

    // Comptage exact : aucun mouvement, l'inventaire se valide quand même.
    const clean = await counted('50', '50');
    expect(clean.body.lines[0].state).toBe('CONFORME');
    await as(tokens.admin)
      .post(`/api/inventories/${clean.id}/validate`)
      .expect(200);
    expect(
      await prisma.stockMovement.count({
        where: { productId: clean.productId, operationType: 'INVENTORY' },
      }),
    ).toBe(0);
    expect(await stockAt(clean.productId, depotId)).toBe('50.000');
  });

  it('une vente survenue depuis le comptage ne bloque RIEN : le delta s’y ajoute', async () => {
    // Prémisse corrigée après la revue du 2026-09-21 : l'ajustement est un
    // DELTA, il ne peut pas écraser un mouvement survenu depuis. Théorique 50,
    // compté 47 → −3 ; vente de 5 → 45 ; −3 appliqué → 42, soit exactement la
    // vérité physique (47 comptés − 5 vendus).
    const inv = await counted('47', '50');

    await prisma.$transaction(async (tx) => {
      await tx.stock.update({
        where: {
          productId_locationId: {
            productId: inv.productId,
            locationId: depotId,
          },
        },
        data: { quantity: { decrement: 5 } },
      });
      await tx.stockMovement.create({
        data: {
          productId: inv.productId,
          locationId: depotId,
          quantity: -5,
          type: 'VENTE',
          operationType: 'SALE',
        },
      });
    });
    expect(await stockAt(inv.productId, depotId)).toBe('45.000');

    await as(tokens.admin)
      .post(`/api/inventories/${inv.id}/validate`)
      .expect(200);
    expect(await stockAt(inv.productId, depotId)).toBe('42.000');

    // La vente est intacte : elle vit toujours dans le journal.
    expect(
      await prisma.stockMovement.count({
        where: { productId: inv.productId, type: 'VENTE' },
      }),
    ).toBe(1);
  });

  it('DOUBLE correction : deux inventaires qui se chevauchent, le second refusé', async () => {
    const first = await counted('47', '50');
    // Un second inventaire compte le MÊME produit avant que le premier soit validé.
    const second = (
      await as(tokens.magasinier)
        .post('/api/inventories')
        .send({
          clientMutationId: randomUUID(),
          locationId: depotId,
          type: 'TOURNANT',
          productIds: [first.productId],
        })
        .expect(201)
    ).body;
    inventoryIds.push(second.id);
    await as(tokens.magasinier)
      .post(`/api/inventories/${second.id}/count`)
      .send({
        done: true,
        lines: [{ productId: first.productId, countedQuantity: '47' }],
      })
      .expect(200);

    await as(tokens.admin)
      .post(`/api/inventories/${first.id}/validate`)
      .expect(200);
    expect(await stockAt(first.productId, depotId)).toBe('47.000');

    // Le second appliquerait −3 une SECONDE fois : refusé.
    const refused = await as(tokens.admin)
      .post(`/api/inventories/${second.id}/validate`)
      .expect(409);
    expect(refused.body.code).toBe('INVENTORY_STALE_COUNT');
    expect(await stockAt(first.productId, depotId)).toBe('47.000');
  });

  it('produit DÉSACTIVÉ : son stock résiduel se régularise quand même (invariant 4)', async () => {
    const inv = await counted('0', '7');
    await prisma.product.update({
      where: { id: inv.productId },
      data: { isActive: false },
    });

    // L'écart est négatif (−7) sur un produit inactif : sans l'exception du
    // journal, l'inventaire entier deviendrait invalidable et ce stock serait
    // gelé pour toujours (aucun autre chemin ne le solde).
    await as(tokens.admin)
      .post(`/api/inventories/${inv.id}/validate`)
      .expect(200);
    expect(await stockAt(inv.productId, depotId)).toBe('0.000');
  });

  it('comptage INCOMPLET : « terminé » est refusé par le SERVEUR', async () => {
    const productId = await productWithStock('20');
    const other = await productWithStock('5');
    const inv = (
      await as(tokens.magasinier)
        .post('/api/inventories')
        .send({
          clientMutationId: randomUUID(),
          locationId: depotId,
          type: 'TOURNANT',
          productIds: [productId, other],
        })
        .expect(201)
    ).body;
    inventoryIds.push(inv.id);

    const refused = await as(tokens.magasinier)
      .post(`/api/inventories/${inv.id}/count`)
      .send({ done: true, lines: [{ productId, countedQuantity: '18' }] })
      .expect(422);
    expect(refused.body.code).toBe('VALIDATION_FAILED');
    expect(refused.body.message).toContain('incomplet');

    // Il reste EN_COURS, donc toujours recomptable.
    const still = (
      await as(tokens.admin).get(`/api/inventories/${inv.id}`).expect(200)
    ).body;
    expect(still.status).toBe('EN_COURS');
  });

  it('même produit deux fois dans un seul envoi de comptage : refusé', async () => {
    const inv = await tournant('10');
    const refused = await as(tokens.magasinier)
      .post(`/api/inventories/${inv.id}/count`)
      .send({
        lines: [
          { productId: inv.productId, countedQuantity: '4' },
          { productId: inv.productId, countedQuantity: '6' },
        ],
      })
      .expect(422);
    expect(refused.body.code).toBe('VALIDATION_FAILED');
  });

  it('le magasinier compte mais ne valide JAMAIS l’ajustement', async () => {
    const inv = await counted('40', '50');
    const refused = await as(tokens.magasinier)
      .post(`/api/inventories/${inv.id}/validate`)
      .expect(403);
    expect(refused.body.code).toBe('FORBIDDEN_ROLE');
    expect(await stockAt(inv.productId, depotId)).toBe('50.000');
  });

  it('le vendeur n’a aucun accès à l’inventaire', async () => {
    const inv = await tournant('10');
    await as(tokens.vendeur).get('/api/inventories').expect(403);
    await as(tokens.vendeur).get(`/api/inventories/${inv.id}`).expect(403);
    await as(tokens.vendeur)
      .post('/api/inventories')
      .send({
        clientMutationId: randomUUID(),
        locationId: depotId,
        type: 'COMPLET',
      })
      .expect(403);
    await as(tokens.vendeur)
      .post(`/api/inventories/${inv.id}/count`)
      .send({ lines: [{ productId: inv.productId, countedQuantity: '1' }] })
      .expect(403);
  });

  it('comptage repris en plusieurs fois, puis clos', async () => {
    const inv = await tournant('50');
    const partial = (
      await as(tokens.magasinier)
        .post(`/api/inventories/${inv.id}/count`)
        .send({
          lines: [{ productId: inv.productId, countedQuantity: '30' }],
        })
        .expect(200)
    ).body;
    expect(partial.status).toBe('EN_COURS');
    expect(partial.lines[0].countedQuantity).toBe('30.000');

    // Tant qu'il n'est pas clos, il ne se valide pas.
    const tooEarly = await as(tokens.admin)
      .post(`/api/inventories/${inv.id}/validate`)
      .expect(409);
    expect(tooEarly.body.code).toBe('INVALID_STATE_TRANSITION');

    // Correction du comptage, puis clôture.
    const done = (
      await as(tokens.magasinier)
        .post(`/api/inventories/${inv.id}/count`)
        .send({
          done: true,
          lines: [{ productId: inv.productId, countedQuantity: '49' }],
        })
        .expect(200)
    ).body;
    expect(done.status).toBe('TERMINE');
    expect(done.lines[0].difference).toBe('-1.000');

    // Terminé, il ne se recompte plus.
    const closed = await as(tokens.magasinier)
      .post(`/api/inventories/${inv.id}/count`)
      .send({ lines: [{ productId: inv.productId, countedQuantity: '48' }] })
      .expect(409);
    expect(closed.body.code).toBe('INVALID_STATE_TRANSITION');
  });

  it('validation rejouée : l’ajustement n’est appliqué qu’UNE fois', async () => {
    const inv = await counted('45', '50');
    await as(tokens.admin)
      .post(`/api/inventories/${inv.id}/validate`)
      .expect(200);
    await as(tokens.admin)
      .post(`/api/inventories/${inv.id}/validate`)
      .expect(200);
    expect(await stockAt(inv.productId, depotId)).toBe('45.000');
    expect(
      await prisma.stockMovement.count({
        where: { productId: inv.productId, operationType: 'INVENTORY' },
      }),
    ).toBe(1);
  });

  it('deux validations SIMULTANÉES : un seul ajustement (verrou de ligne)', async () => {
    const inv = await counted('44', '50');
    const [a, b] = await Promise.all([
      as(tokens.admin).post(`/api/inventories/${inv.id}/validate`),
      as(tokens.admin).post(`/api/inventories/${inv.id}/validate`),
    ]);
    expect([a.status, b.status]).toEqual([200, 200]);
    expect(await stockAt(inv.productId, depotId)).toBe('44.000');
    expect(
      await prisma.stockMovement.count({
        where: { productId: inv.productId, operationType: 'INVENTORY' },
      }),
    ).toBe(1);
  });

  it('un inventaire COMPLET fige tout le lieu et refuse une liste de produits', async () => {
    const productId = await productWithStock('12');
    const refused = await as(tokens.magasinier)
      .post('/api/inventories')
      .send({
        clientMutationId: randomUUID(),
        locationId: depotId,
        type: 'COMPLET',
        productIds: [productId],
      })
      .expect(422);
    expect(refused.body.code).toBe('VALIDATION_FAILED');

    const complet = (
      await as(tokens.magasinier)
        .post('/api/inventories')
        .send({
          clientMutationId: randomUUID(),
          locationId: depotId,
          type: 'COMPLET',
        })
        .expect(201)
    ).body;
    inventoryIds.push(complet.id);
    // Le produit qu'on vient de créer au dépôt fait partie du périmètre.
    const line = complet.lines.find(
      (l: { productId: string }) => l.productId === productId,
    );
    expect(line).toMatchObject({ theoreticalQuantity: '12.000' });
  });

  it('un inventaire TOURNANT exige sa liste de produits', async () => {
    const refused = await as(tokens.magasinier)
      .post('/api/inventories')
      .send({
        clientMutationId: randomUUID(),
        locationId: depotId,
        type: 'TOURNANT',
        zone: 'Zone B',
      })
      .expect(422);
    expect(refused.body.code).toBe('VALIDATION_FAILED');
  });

  it('on n’inventorie ni le transit, ni un produit étranger à l’inventaire', async () => {
    const productId = await productWithStock('5');
    const transit = await as(tokens.magasinier)
      .post('/api/inventories')
      .send({
        clientMutationId: randomUUID(),
        locationId: transitId,
        type: 'TOURNANT',
        productIds: [productId],
      })
      .expect(422);
    expect(transit.body.code).toBe('VALIDATION_FAILED');

    const inv = await tournant('5');
    const stranger = await as(tokens.magasinier)
      .post(`/api/inventories/${inv.id}/count`)
      .send({ lines: [{ productId, countedQuantity: '1' }] })
      .expect(422);
    expect(stranger.body.code).toBe('VALIDATION_FAILED');
  });

  it('même clé : un seul inventaire ; autre périmètre sur la même clé : 409', async () => {
    const productId = await productWithStock('9');
    const key = randomUUID();
    const payload = {
      clientMutationId: key,
      locationId: depotId,
      type: 'TOURNANT',
      productIds: [productId],
    };
    const first = (
      await as(tokens.magasinier)
        .post('/api/inventories')
        .send(payload)
        .expect(201)
    ).body;
    inventoryIds.push(first.id);
    const replayed = (
      await as(tokens.magasinier)
        .post('/api/inventories')
        .send(payload)
        .expect(201)
    ).body;
    expect(replayed.id).toBe(first.id);
    expect(
      await prisma.inventory.count({ where: { clientMutationId: key } }),
    ).toBe(1);

    const conflict = await as(tokens.magasinier)
      .post('/api/inventories')
      .send({ ...payload, locationId: magasinId })
      .expect(409);
    expect(conflict.body.code).toBe('CONFLICT');
  });

  it('entrées mal formées : statut forgé, tri libre, quantité illisible', async () => {
    // `in` traverserait la chaîne de prototypes : aucun ne doit atteindre Prisma.
    for (const status of ['PERDU', 'constructor', 'toString']) {
      const bad = await as(tokens.admin)
        .get(`/api/inventories?status=${status}`)
        .expect(400);
      expect(bad.body.code).toBe('VALIDATION_FAILED');
    }
    const badSort = await as(tokens.admin)
      .get('/api/inventories?sort=note:asc')
      .expect(400);
    expect(badSort.body.code).toBe('VALIDATION_FAILED');

    const inv = await tournant('5');
    await as(tokens.magasinier)
      .post(`/api/inventories/${inv.id}/count`)
      .send({ lines: [{ productId: inv.productId, countedQuantity: '1,5' }] })
      .expect(400);
  });

  it('chaque étape est tracée, et la validation dit combien de lignes sont ajustées', async () => {
    const inv = await counted('42', '50');
    await as(tokens.admin)
      .post(`/api/inventories/${inv.id}/validate`)
      .expect(200);

    const trail = await prisma.auditLog.findMany({
      where: { entityType: 'Inventory', entityId: inv.id },
      orderBy: [{ createdAt: 'asc' }, { id: 'asc' }],
    });
    // Le comptage n'ajuste rien : c'est un UPDATE. Seule la validation ajuste.
    expect(trail.map((entry) => entry.action)).toEqual([
      'CREATE',
      'UPDATE',
      'VALIDATE',
    ]);
    const last = trail[trail.length - 1];
    expect((last.newValue as { adjustedLines: number }).adjustedLines).toBe(1);
  });
});
