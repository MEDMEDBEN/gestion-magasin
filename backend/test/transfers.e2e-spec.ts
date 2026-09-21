import { randomUUID } from 'crypto';
import * as request from 'supertest';
import { RoleCode } from '../src/common/auth.decorators';
import { PrismaService } from '../src/prisma/prisma.service';
import { createE2eApp, createTestUser, E2eApp } from './helpers/e2e-app';

/// Transferts dépôt → magasin (P0 n°8, spec §16 et §17).
///
/// Ce qui est éprouvé ici en priorité : le STOCK (dépôt → transit → magasin, et
/// jamais vendable au magasin avant réception), les TRANSITIONS d'état, la
/// MATRICE de rôles de `docs/permissions.md`, et la concurrence expédition ↔ refus.
describe('Transferts magasin ↔ dépôt (e2e)', () => {
  let e2e: E2eApp;
  let prisma: PrismaService;
  let server: E2eApp['server'];

  const suffix = Date.now();
  const PASSWORD = 'MotDePasseTemp1!';
  const userIds: string[] = [];
  const productIds: string[] = [];
  const transferIds: string[] = [];
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

  /// Produit avec `quantity` unités DÉJÀ au dépôt (entrées par le journal via
  /// `initialStock` : aucun test n'écrit `Stock.quantity` à la main, règle 2).
  const productWithStock = async (quantity = '100') => {
    const n = ++counter;
    const created = (
      await as(tokens.admin)
        .post('/api/products')
        .send({
          sku: `E2E-TRF-${suffix}-${n}`,
          name: `Produit transfert ${n}`,
          unit: 'PIECE',
          initialStock: [{ locationId: depotId, quantity }],
        })
        .expect(201)
    ).body;
    productIds.push(created.id);
    return created.id as string;
  };

  /// Demande du vendeur : `quantity` unités d'un produit neuf.
  const requested = async (quantity = '20', stock = '100') => {
    const productId = await productWithStock(stock);
    const transfer = (
      await as(tokens.vendeur)
        .post('/api/transfers')
        .send({
          clientMutationId: randomUUID(),
          lines: [{ productId, quantity }],
        })
        .expect(201)
    ).body;
    transferIds.push(transfer.id);
    return { id: transfer.id as string, productId, body: transfer };
  };

  const stockAt = async (productId: string, locationId: string) =>
    (
      await prisma.stock.findFirst({ where: { productId, locationId } })
    )?.quantity.toFixed(3) ?? '0.000';

  /// Demande préparée et expédiée : `prepared` unités sont en transit.
  const shipped = async (asked = '20', prepared = '18', stock = '100') => {
    const transfer = await requested(asked, stock);
    await as(tokens.magasinier)
      .post(`/api/transfers/${transfer.id}/prepare`)
      .send({
        lines: [{ productId: transfer.productId, preparedQuantity: prepared }],
      })
      .expect(200);
    const body = (
      await as(tokens.magasinier)
        .post(`/api/transfers/${transfer.id}/ship`)
        .expect(200)
    ).body;
    return { ...transfer, body };
  };

  beforeAll(async () => {
    e2e = await createE2eApp();
    prisma = e2e.prisma;
    server = e2e.server;
    for (const [key, role] of [
      ['admin', RoleCode.ADMIN],
      ['magasinier', RoleCode.MAGASINIER],
      ['vendeur', RoleCode.VENDEUR],
      ['vendeur2', RoleCode.VENDEUR],
    ] as const) {
      const email = `e2e-transfert-${key}-${suffix}@test.local`;
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
    await prisma.transferLine.deleteMany({
      where: { transferId: { in: transferIds } },
    });
    await prisma.transfer.deleteMany({ where: { id: { in: transferIds } } });
    await prisma.stockMovement.deleteMany({
      where: { productId: { in: productIds } },
    });
    await prisma.stock.deleteMany({ where: { productId: { in: productIds } } });
    await prisma.product.deleteMany({ where: { id: { in: productIds } } });
    await prisma.user.deleteMany({ where: { id: { in: userIds } } });
    await e2e.app.close();
  });

  it('flux complet : demande → acceptée → préparée → transit → reçue', async () => {
    const transfer = await requested('20', '100');
    expect(transfer.body.number).toMatch(/^TRF-\d{4}-\d{5}$/);
    expect(transfer.body.status).toBe('DEMANDEE');
    expect(transfer.body.fromLocationId).toBe(depotId);
    expect(transfer.body.toLocationId).toBe(magasinId);

    const accepted = (
      await as(tokens.magasinier)
        .post(`/api/transfers/${transfer.id}/accept`)
        .expect(200)
    ).body;
    expect(accepted.status).toBe('ACCEPTEE');

    // Préparation PARTIELLE : 18 sur 20 demandés (spec §17).
    const prepared = (
      await as(tokens.magasinier)
        .post(`/api/transfers/${transfer.id}/prepare`)
        .send({
          lines: [{ productId: transfer.productId, preparedQuantity: '18' }],
        })
        .expect(200)
    ).body;
    expect(prepared.status).toBe('PREPAREE');
    expect(prepared.lines[0].preparedQuantity).toBe('18.000');
    // Rien n'a encore bougé : la préparation ne déplace aucun stock.
    expect(await stockAt(transfer.productId, depotId)).toBe('100.000');

    const inTransit = (
      await as(tokens.magasinier)
        .post(`/api/transfers/${transfer.id}/ship`)
        .expect(200)
    ).body;
    expect(inTransit.status).toBe('EN_TRANSIT');
    expect(inTransit.lines[0].shippedQuantity).toBe('18.000');
    // Spec §17 : le produit n'est pas disponible au magasin, il est EN TRANSIT.
    expect(await stockAt(transfer.productId, depotId)).toBe('82.000');
    expect(await stockAt(transfer.productId, transitId)).toBe('18.000');
    expect(await stockAt(transfer.productId, magasinId)).toBe('0.000');

    const received = (
      await as(tokens.vendeur)
        .post(`/api/transfers/${transfer.id}/receive`)
        .send({})
        .expect(200)
    ).body;
    expect(received.status).toBe('RECUE');
    expect(received.lines[0].receivedQuantity).toBe('18.000');
    expect(await stockAt(transfer.productId, transitId)).toBe('0.000');
    expect(await stockAt(transfer.productId, magasinId)).toBe('18.000');
    expect(await stockAt(transfer.productId, depotId)).toBe('82.000');

    // Le journal porte la sortie du dépôt et l'entrée au magasin (règle 2).
    const movements = await prisma.stockMovement.findMany({
      where: { productId: transfer.productId, operationId: transfer.id },
      orderBy: { id: 'asc' },
    });
    expect(movements).toHaveLength(4);
    expect(movements.map((m) => m.type)).toEqual([
      'TRANSFERT_SORTIE',
      'TRANSFERT_ENTREE',
      'TRANSFERT_SORTIE',
      'TRANSFERT_ENTREE',
    ]);
    expect(movements.every((m) => m.operationType === 'TRANSFER')).toBe(true);
  });

  it('écart à la réception : le manquant RETOURNE au dépôt, le transit se vide', async () => {
    const transfer = await shipped('20', '18', '100');
    expect(await stockAt(transfer.productId, transitId)).toBe('18.000');

    const received = (
      await as(tokens.vendeur)
        .post(`/api/transfers/${transfer.id}/receive`)
        .send({
          lines: [{ productId: transfer.productId, receivedQuantity: '15' }],
        })
        .expect(200)
    ).body;
    expect(received.status).toBe('RECUE');
    expect(received.lines[0]).toMatchObject({
      shippedQuantity: '18.000',
      receivedQuantity: '15.000',
    });
    // 15 arrivés au magasin, 3 rendus au dépôt : rien ne reste coincé en transit.
    expect(await stockAt(transfer.productId, magasinId)).toBe('15.000');
    expect(await stockAt(transfer.productId, transitId)).toBe('0.000');
    expect(await stockAt(transfer.productId, depotId)).toBe('85.000');

    const ecart = await prisma.stockMovement.findFirstOrThrow({
      where: {
        productId: transfer.productId,
        operationId: transfer.id,
        locationId: depotId,
        type: 'TRANSFERT_ENTREE',
      },
    });
    expect(ecart.quantity.toFixed(3)).toBe('3.000');
    expect(ecart.comment).toContain('écart de transfert');
    // Traçabilité du schéma Phase 0 : d'où part la marchandise, où elle va.
    expect(ecart.sourceLocationId).toBe(transitId);
    expect(ecart.destinationLocationId).toBe(depotId);
  });

  it('stock insuffisant au dépôt : expédition refusée, RIEN ne bouge', async () => {
    const transfer = await requested('50', '10');
    await as(tokens.magasinier)
      .post(`/api/transfers/${transfer.id}/prepare`)
      .send({
        lines: [{ productId: transfer.productId, preparedQuantity: '50' }],
      })
      .expect(200);

    const refused = await as(tokens.magasinier)
      .post(`/api/transfers/${transfer.id}/ship`)
      .expect(422);
    expect(refused.body.code).toBe('STOCK_NEGATIVE');

    // Atomicité : ni statut, ni stock, ni transit touchés.
    expect(await stockAt(transfer.productId, depotId)).toBe('10.000');
    expect(await stockAt(transfer.productId, transitId)).toBe('0.000');
    const after = (
      await as(tokens.magasinier)
        .get(`/api/transfers/${transfer.id}`)
        .expect(200)
    ).body;
    expect(after.status).toBe('PREPAREE');
  });

  it('préparer plus que demandé, ou recevoir plus qu’expédié : refusé', async () => {
    const transfer = await requested('20', '100');
    const tooMuch = await as(tokens.magasinier)
      .post(`/api/transfers/${transfer.id}/prepare`)
      .send({
        lines: [{ productId: transfer.productId, preparedQuantity: '21' }],
      })
      .expect(422);
    expect(tooMuch.body.code).toBe('VALIDATION_FAILED');

    const sent = await shipped('20', '18', '100');
    const overReceived = await as(tokens.vendeur)
      .post(`/api/transfers/${sent.id}/receive`)
      .send({
        lines: [{ productId: sent.productId, receivedQuantity: '19' }],
      })
      .expect(422);
    expect(overReceived.body.code).toBe('VALIDATION_FAILED');
    expect(await stockAt(sent.productId, magasinId)).toBe('0.000');
  });

  it('préparation en cours puis reprise : EN_PREPARATION ne s’expédie pas', async () => {
    const transfer = await requested('20', '100');
    const draft = (
      await as(tokens.magasinier)
        .post(`/api/transfers/${transfer.id}/prepare`)
        .send({
          done: false,
          lines: [{ productId: transfer.productId, preparedQuantity: '5' }],
        })
        .expect(200)
    ).body;
    expect(draft.status).toBe('EN_PREPARATION');
    expect(draft.lines[0].preparedQuantity).toBe('5.000');

    const tooEarly = await as(tokens.magasinier)
      .post(`/api/transfers/${transfer.id}/ship`)
      .expect(409);
    expect(tooEarly.body.code).toBe('INVALID_STATE_TRANSITION');

    const done = (
      await as(tokens.magasinier)
        .post(`/api/transfers/${transfer.id}/prepare`)
        .send({
          lines: [{ productId: transfer.productId, preparedQuantity: '12' }],
        })
        .expect(200)
    ).body;
    expect(done.status).toBe('PREPAREE');
    expect(done.lines[0].preparedQuantity).toBe('12.000');
  });

  it('rien de préparé : on refuse la demande, on ne l’expédie pas à vide', async () => {
    const transfer = await requested('20', '100');
    await as(tokens.magasinier)
      .post(`/api/transfers/${transfer.id}/prepare`)
      .send({
        lines: [{ productId: transfer.productId, preparedQuantity: '0' }],
      })
      .expect(200);
    const refused = await as(tokens.magasinier)
      .post(`/api/transfers/${transfer.id}/ship`)
      .expect(409);
    expect(refused.body.code).toBe('INVALID_STATE_TRANSITION');
  });

  it('matrice des rôles : chacun ne fait que son étape', async () => {
    const transfer = await requested('20', '100');

    // Le magasinier ne DEMANDE pas (la demande vient du magasin).
    await as(tokens.magasinier)
      .post('/api/transfers')
      .send({
        clientMutationId: randomUUID(),
        lines: [{ productId: transfer.productId, quantity: '1' }],
      })
      .expect(403);
    // Le vendeur ne PRÉPARE pas et n'EXPÉDIE pas (c'est le dépôt).
    await as(tokens.vendeur)
      .post(`/api/transfers/${transfer.id}/prepare`)
      .send({
        lines: [{ productId: transfer.productId, preparedQuantity: '1' }],
      })
      .expect(403);
    await as(tokens.vendeur)
      .post(`/api/transfers/${transfer.id}/ship`)
      .expect(403);
    // Le magasinier ne RÉCEPTIONNE pas au magasin.
    await as(tokens.magasinier)
      .post(`/api/transfers/${transfer.id}/receive`)
      .send({})
      .expect(403);
    // Les trois rôles voient le même tableau.
    for (const key of ['admin', 'vendeur', 'magasinier']) {
      await as(tokens[key]).get('/api/transfers?limit=5').expect(200);
    }
  });

  it('refus par le dépôt, annulation par l’auteur : chacun son geste', async () => {
    // Le magasinier REFUSE, il n'annule pas.
    const toRefuse = await requested('20', '100');
    const notCancel = await as(tokens.magasinier)
      .post(`/api/transfers/${toRefuse.id}/cancel`)
      .send({ status: 'ANNULEE' })
      .expect(403);
    expect(notCancel.body.code).toBe('FORBIDDEN_ROLE');
    const refused = (
      await as(tokens.magasinier)
        .post(`/api/transfers/${toRefuse.id}/cancel`)
        .send({ status: 'REFUSEE' })
        .expect(200)
    ).body;
    expect(refused.status).toBe('REFUSEE');

    // Un AUTRE vendeur n'annule pas la demande de son collègue ; l'auteur, oui.
    const toCancel = await requested('20', '100');
    const other = await as(tokens.vendeur2)
      .post(`/api/transfers/${toCancel.id}/cancel`)
      .send({ status: 'ANNULEE' })
      .expect(403);
    expect(other.body.code).toBe('FORBIDDEN_ROLE');
    // Et il ne refuse pas non plus : ce n'est pas le dépôt.
    await as(tokens.vendeur2)
      .post(`/api/transfers/${toCancel.id}/cancel`)
      .send({ status: 'REFUSEE' })
      .expect(403);
    const cancelled = (
      await as(tokens.vendeur)
        .post(`/api/transfers/${toCancel.id}/cancel`)
        .send({ status: 'ANNULEE' })
        .expect(200)
    ).body;
    expect(cancelled.status).toBe('ANNULEE');
  });

  it('marchandise partie : plus d’annulation, et pas de double réception', async () => {
    const transfer = await shipped('20', '18', '100');
    const tooLate = await as(tokens.admin)
      .post(`/api/transfers/${transfer.id}/cancel`)
      .send({ status: 'ANNULEE' })
      .expect(409);
    expect(tooLate.body.code).toBe('INVALID_STATE_TRANSITION');

    await as(tokens.vendeur)
      .post(`/api/transfers/${transfer.id}/receive`)
      .send({})
      .expect(200);
    const again = await as(tokens.vendeur)
      .post(`/api/transfers/${transfer.id}/receive`)
      .send({})
      .expect(409);
    expect(again.body.code).toBe('INVALID_STATE_TRANSITION');
    // La marchandise n'est entrée qu'UNE fois.
    expect(await stockAt(transfer.productId, magasinId)).toBe('18.000');
  });

  it('même clé : une seule demande ; clé réutilisée pour autre chose : 409', async () => {
    const productId = await productWithStock('100');
    const key = randomUUID();
    const payload = {
      clientMutationId: key,
      lines: [{ productId, quantity: '7' }],
    };
    const first = (
      await as(tokens.vendeur).post('/api/transfers').send(payload).expect(201)
    ).body;
    transferIds.push(first.id);
    const replayed = (
      await as(tokens.vendeur).post('/api/transfers').send(payload).expect(201)
    ).body;
    expect(replayed.id).toBe(first.id);
    expect(
      await prisma.transfer.count({ where: { clientMutationId: key } }),
    ).toBe(1);

    const conflict = await as(tokens.vendeur)
      .post('/api/transfers')
      .send({ clientMutationId: key, lines: [{ productId, quantity: '8' }] })
      .expect(409);
    expect(conflict.body.code).toBe('CONFLICT');
  });

  it('expédition et refus SIMULTANÉS : un seul passe (verrou de ligne)', async () => {
    const transfer = await requested('10', '100');
    await as(tokens.magasinier)
      .post(`/api/transfers/${transfer.id}/prepare`)
      .send({
        lines: [{ productId: transfer.productId, preparedQuantity: '10' }],
      })
      .expect(200);

    const [ship, refuse] = await Promise.all([
      as(tokens.magasinier).post(`/api/transfers/${transfer.id}/ship`),
      as(tokens.admin)
        .post(`/api/transfers/${transfer.id}/cancel`)
        .send({ status: 'REFUSEE' }),
    ]);
    const codes = [ship.status, refuse.status].sort();
    expect(codes).toEqual([200, 409]);

    const final = (
      await as(tokens.admin).get(`/api/transfers/${transfer.id}`).expect(200)
    ).body;
    // Refusé → rien n'est parti ; expédié → tout est en transit. Jamais les deux.
    if (final.status === 'REFUSEE') {
      expect(await stockAt(transfer.productId, transitId)).toBe('0.000');
      expect(await stockAt(transfer.productId, depotId)).toBe('100.000');
    } else {
      expect(final.status).toBe('EN_TRANSIT');
      expect(await stockAt(transfer.productId, transitId)).toBe('10.000');
      expect(await stockAt(transfer.productId, depotId)).toBe('90.000');
    }
  });

  it('demande mal formée : produit inconnu, doublon, quantité illisible, tri libre', async () => {
    const productId = await productWithStock('10');
    const base = { clientMutationId: randomUUID() };

    const unknown = await as(tokens.vendeur)
      .post('/api/transfers')
      .send({ ...base, lines: [{ productId: randomUUID(), quantity: '1' }] })
      .expect(422);
    expect(unknown.body.code).toBe('VALIDATION_FAILED');

    const duplicate = await as(tokens.vendeur)
      .post('/api/transfers')
      .send({
        clientMutationId: randomUUID(),
        lines: [
          { productId, quantity: '1' },
          { productId, quantity: '2' },
        ],
      })
      .expect(422);
    expect(duplicate.body.code).toBe('VALIDATION_FAILED');

    await as(tokens.vendeur)
      .post('/api/transfers')
      .send({
        clientMutationId: randomUUID(),
        lines: [{ productId, quantity: '1,5' }],
      })
      .expect(400);

    const badSort = await as(tokens.admin)
      .get('/api/transfers?sort=comment:asc')
      .expect(400);
    expect(badSort.body.code).toBe('VALIDATION_FAILED');

    // `PERDUE` n'existe pas ; `constructor` et `toString` EXISTENT sur le
    // prototype de l'objet d'énum : aucun des trois ne doit atteindre Prisma.
    for (const status of ['PERDUE', 'constructor', 'toString']) {
      const badStatus = await as(tokens.admin)
        .get(`/api/transfers?status=${status}`)
        .expect(400);
      expect(badStatus.body.code).toBe('VALIDATION_FAILED');
    }
  });

  it('emplacements : omis, le serveur les résout ; d’une autre espèce, refusés', async () => {
    const productId = await productWithStock('10');
    // Le sens du flux ne s'inverse pas : le magasin ne peut pas être l'origine.
    const wrongWay = await as(tokens.vendeur)
      .post('/api/transfers')
      .send({
        clientMutationId: randomUUID(),
        fromLocationId: magasinId,
        toLocationId: depotId,
        lines: [{ productId, quantity: '1' }],
      })
      .expect(422);
    expect(wrongWay.body.code).toBe('VALIDATION_FAILED');

    // Fournis correctement, ils sont acceptés tels quels.
    const explicit = (
      await as(tokens.vendeur)
        .post('/api/transfers')
        .send({
          clientMutationId: randomUUID(),
          fromLocationId: depotId,
          toLocationId: magasinId,
          lines: [{ productId, quantity: '1' }],
        })
        .expect(201)
    ).body;
    transferIds.push(explicit.id);
    expect(explicit.fromLocationId).toBe(depotId);
  });

  it('produit désactivé : plus de demande, mais un transit en cours arrive quand même', async () => {
    // Règle 7 : une opération inverse / en cours ne se bloque jamais.
    const transfer = await shipped('10', '10', '50');
    await prisma.product.update({
      where: { id: transfer.productId },
      data: { isActive: false },
    });

    await as(tokens.vendeur)
      .post('/api/transfers')
      .send({
        clientMutationId: randomUUID(),
        lines: [{ productId: transfer.productId, quantity: '1' }],
      })
      .expect(422);

    await as(tokens.vendeur)
      .post(`/api/transfers/${transfer.id}/receive`)
      .send({})
      .expect(200);
    expect(await stockAt(transfer.productId, magasinId)).toBe('10.000');
    expect(await stockAt(transfer.productId, transitId)).toBe('0.000');
  });

  it('chaque étape est tracée dans l’audit, avec son auteur', async () => {
    const transfer = await shipped('10', '10', '50');
    await as(tokens.vendeur)
      .post(`/api/transfers/${transfer.id}/receive`)
      .send({})
      .expect(200);

    const trail = await prisma.auditLog.findMany({
      where: { entityType: 'Transfer', entityId: transfer.id },
      orderBy: [{ createdAt: 'asc' }, { id: 'asc' }],
    });
    expect(trail.map((entry) => entry.action)).toEqual([
      'CREATE',
      'UPDATE',
      'UPDATE',
      'UPDATE',
    ]);
    const last = trail[trail.length - 1];
    expect((last.newValue as { status: string }).status).toBe('RECUE');
    expect((last.oldValue as { status: string }).status).toBe('EN_TRANSIT');
  });
});
