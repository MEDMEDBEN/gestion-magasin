import * as request from 'supertest';
import { RoleCode } from '../src/common/auth.decorators';
import { PrismaService } from '../src/prisma/prisma.service';
import { createE2eApp, createTestUser, E2eApp } from './helpers/e2e-app';

/// Signalement de problème (P1 n°18, spec §26).
///
/// Éprouvé en priorité : la machine à états ne se saute pas ; RÉSOLU exige une
/// explication ; attribuer et fermer restent à l'ADMIN ; un signalement ne
/// touche JAMAIS au stock.
describe('Signalements (e2e)', () => {
  let e2e: E2eApp;
  let prisma: PrismaService;
  let server: E2eApp['server'];

  const suffix = Date.now();
  const PASSWORD = 'MotDePasseTemp1!';
  const userIds: string[] = [];
  const productIds: string[] = [];
  const ids: Record<string, string> = {};
  const tokens: Record<string, string> = {};
  let productId: string;

  const as = (token: string) => ({
    get: (url: string) =>
      request(server).get(url).set('Authorization', `Bearer ${token}`),
    post: (url: string) =>
      request(server).post(url).set('Authorization', `Bearer ${token}`),
  });

  const report = async (who = 'magasinier', extra: object = {}) =>
    (
      await as(tokens[who])
        .post('/api/problems')
        .send({
          title: `Stock faux câble ${Math.random().toString(36).slice(2, 7)}`,
          category: 'STOCK_INCORRECT',
          description: 'Le système annonce 40, il y en a 12 sur l’étagère.',
          productId,
          ...extra,
        })
        .expect(201)
    ).body;

  beforeAll(async () => {
    e2e = await createE2eApp();
    prisma = e2e.prisma;
    server = e2e.server;
    const product = await prisma.product.create({
      data: {
        sku: `E2E-PROB-${suffix}`,
        barcode: `E2E-PROB-BC-${suffix}`,
        name: 'Câble signalé',
      },
    });
    productId = product.id;
    productIds.push(product.id);

    for (const [key, role] of [
      ['admin', RoleCode.ADMIN],
      ['vendeur', RoleCode.VENDEUR],
      ['magasinier', RoleCode.MAGASINIER],
      ['autre', RoleCode.MAGASINIER],
    ] as const) {
      const email = `e2e-prob-${key}-${suffix}@test.local`;
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
    await prisma.notification.deleteMany({
      where: { userId: { in: userIds } },
    });
    await prisma.problem.deleteMany({
      where: { reportedById: { in: userIds } },
    });
    await prisma.auditLog.deleteMany({ where: { userId: { in: userIds } } });
    await prisma.product.deleteMany({ where: { id: { in: productIds } } });
    await prisma.user.deleteMany({ where: { id: { in: userIds } } });
    await e2e.app.close();
  });

  it('les trois rôles peuvent signaler, et l’admin est prévenu', async () => {
    for (const who of ['vendeur', 'magasinier', 'admin']) {
      const problem = await report(who);
      expect(problem).toMatchObject({
        status: 'OUVERT',
        priority: 'NORMALE',
        reportedById: ids[who],
        hasPhoto: false,
        assignedToId: null,
      });
      expect(problem.productName).toBe('Câble signalé');
    }

    // Prévenu de ceux des autres, pas du sien.
    const alerts = await prisma.notification.findMany({
      where: { userId: ids.admin, type: 'PROBLEME' },
    });
    expect(alerts).toHaveLength(2);
  });

  it('un signalement ne touche PAS au stock', async () => {
    const avant = await prisma.stockMovement.count({ where: { productId } });
    await report();
    expect(await prisma.stockMovement.count({ where: { productId } })).toBe(
      avant,
    );
  });

  it('cycle complet : pris en charge, résolu avec explication, fermé par l’admin', async () => {
    const problem = await report();

    const encours = (
      await as(tokens.magasinier)
        .post(`/api/problems/${problem.id}/start`)
        .expect(200)
    ).body;
    expect(encours.status).toBe('EN_COURS');
    // Le prendre se l'attribue : pas d'« en cours » sans responsable.
    expect(encours.assignedToId).toBe(ids.magasinier);

    const resolu = (
      await as(tokens.magasinier)
        .post(`/api/problems/${problem.id}/resolve`)
        .send({
          resolution: 'Inventaire tournant fait, écart ajusté par l’admin.',
        })
        .expect(200)
    ).body;
    expect(resolu.status).toBe('RESOLU');
    expect(resolu.resolution).toContain('Inventaire tournant');
    expect(resolu.resolvedAt).not.toBeNull();

    const ferme = (
      await as(tokens.admin)
        .post(`/api/problems/${problem.id}/close`)
        .expect(200)
    ).body;
    expect(ferme.status).toBe('FERME');
    expect(ferme.closedAt).not.toBeNull();
  });

  it('RÉSOLU sans explication : refusé', async () => {
    const problem = await report();
    await as(tokens.magasinier)
      .post(`/api/problems/${problem.id}/resolve`)
      .send({ resolution: '' })
      .expect(400);
    await as(tokens.magasinier)
      .post(`/api/problems/${problem.id}/resolve`)
      .send({})
      .expect(400);
  });

  it('on ne ferme PAS un signalement qui n’a jamais été traité', async () => {
    const problem = await report();
    const refus = await as(tokens.admin)
      .post(`/api/problems/${problem.id}/close`)
      .expect(409);
    expect(refus.body.code).toBe('INVALID_STATE_TRANSITION');
  });

  it('attribuer et fermer sont réservés à l’ADMIN', async () => {
    const problem = await report();
    await as(tokens.magasinier)
      .post(`/api/problems/${problem.id}/assign`)
      .send({ assignedToId: ids.autre })
      .expect(403);
    await as(tokens.vendeur)
      .post(`/api/problems/${problem.id}/close`)
      .expect(403);
  });

  it('un signalement confié à quelqu’un n’est pas repris par un autre', async () => {
    const problem = await report();
    const assigne = (
      await as(tokens.admin)
        .post(`/api/problems/${problem.id}/assign`)
        .send({ assignedToId: ids.magasinier })
        .expect(200)
    ).body;
    expect(assigne.assignedToId).toBe(ids.magasinier);
    // Le membre désigné est prévenu.
    expect(
      await prisma.notification.count({
        where: { userId: ids.magasinier, operationId: problem.id },
      }),
    ).toBe(1);

    await as(tokens.autre)
      .post(`/api/problems/${problem.id}/start`)
      .expect(403);
    // L'admin, lui, peut toujours agir.
    await as(tokens.admin)
      .post(`/api/problems/${problem.id}/start`)
      .expect(200);
  });

  it('celui qui a signalé apprend que c’est résolu', async () => {
    const problem = await report('vendeur');
    const avant = await prisma.notification.count({
      where: { userId: ids.vendeur, operationId: problem.id },
    });

    await as(tokens.admin)
      .post(`/api/problems/${problem.id}/resolve`)
      .send({ resolution: 'Poste redémarré, l’imprimante répond.' })
      .expect(200);

    expect(
      await prisma.notification.count({
        where: { userId: ids.vendeur, operationId: problem.id },
      }),
    ).toBe(avant + 1);
  });

  it('un signalement clos ne se retouche plus', async () => {
    const problem = await report();
    await as(tokens.admin)
      .post(`/api/problems/${problem.id}/resolve`)
      .send({ resolution: 'Corrigé.' })
      .expect(200);

    await as(tokens.magasinier)
      .post(`/api/problems/${problem.id}/start`)
      .expect(409);
    await as(tokens.admin)
      .post(`/api/problems/${problem.id}/assign`)
      .send({ assignedToId: ids.autre })
      .expect(409);
  });

  it('filtres : par statut et « ceux que j’ai signalés »', async () => {
    const mien = await report('vendeur');

    const parStatut = (
      await as(tokens.vendeur).get('/api/problems?status=OUVERT').expect(200)
    ).body;
    expect(
      parStatut.data.every((p: { status: string }) => p.status === 'OUVERT'),
    ).toBe(true);

    const miens = (
      await as(tokens.vendeur).get('/api/problems?mine=true').expect(200)
    ).body;
    expect(
      miens.data.every(
        (p: { reportedById: string }) => p.reportedById === ids.vendeur,
      ),
    ).toBe(true);
    expect(miens.data.map((p: { id: string }) => p.id)).toContain(mien.id);
  });

  it('produit inexistant : refusé', async () => {
    await as(tokens.magasinier)
      .post('/api/problems')
      .send({
        title: 'Produit fantôme',
        category: 'AUTRE',
        description: 'Ce produit n’existe pas.',
        productId: '01920000-0000-7000-8000-000000000000',
      })
      .expect(422);
  });

  /// PNG 1×1 réel : le serveur lit le format dans les OCTETS, un buffer bidon
  /// ne passerait pas la vérification de type.
  const PNG = Buffer.from(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==',
    'base64',
  );

  it('photo : l’auteur la joint, toute l’équipe la lit, les octets sont intacts', async () => {
    const problem = await report();
    const posee = (
      await as(tokens.magasinier)
        .post(`/api/problems/${problem.id}/photo`)
        .attach('file', PNG, 'photo.png')
        .expect(200)
    ).body;
    expect(posee.hasPhoto).toBe(true);

    for (const who of ['admin', 'vendeur', 'magasinier']) {
      const image = await as(tokens[who])
        .get(`/api/problems/${problem.id}/photo`)
        .buffer(true)
        .parse((res, done) => {
          const chunks: Buffer[] = [];
          res.on('data', (c: Buffer) => chunks.push(c));
          res.on('end', () => done(null, Buffer.concat(chunks)));
        })
        .expect(200);
      expect(image.headers['content-type']).toBe('image/png');
      expect(image.headers['x-content-type-options']).toBe('nosniff');
      expect(Buffer.compare(image.body as Buffer, PNG)).toBe(0);
    }
    // Le stockage est privé : aucune URL publique.
    await request(server).get(`/api/problems/${problem.id}/photo`).expect(401);
  });

  it('photo : au-delà de 2 Mo, refusée AVANT d’être lue en entier', async () => {
    const problem = await report();
    const enorme = Buffer.concat([PNG, Buffer.alloc(2 * 1024 * 1024)]);
    await as(tokens.magasinier)
      .post(`/api/problems/${problem.id}/photo`)
      .attach('file', enorme, 'enorme.png')
      .expect(413);
    await as(tokens.magasinier)
      .get(`/api/problems/${problem.id}/photo`)
      .expect(404);
  });

  /// Règle 7 : un signalement clos ne se retouche plus, `photoKey` compris. La
  /// garde est DANS la transaction, parce qu'écrire 2 Mo sur le disque laisse
  /// tout le temps à l'admin de fermer entre-temps.
  it('photo : refusée sur un signalement déjà résolu', async () => {
    const problem = await report();
    await as(tokens.admin)
      .post(`/api/problems/${problem.id}/resolve`)
      .send({ resolution: 'Corrigé par inventaire.' })
      .expect(200);

    await as(tokens.magasinier)
      .post(`/api/problems/${problem.id}/photo`)
      .attach('file', PNG, 'photo.png')
      .expect(409);
    // Et rien n'a été posé : la lecture répond toujours 404.
    await as(tokens.magasinier)
      .get(`/api/problems/${problem.id}/photo`)
      .expect(404);
  });

  it('photo : un tiers ne joint rien au signalement d’un autre', async () => {
    const problem = await report();
    await as(tokens.autre)
      .post(`/api/problems/${problem.id}/photo`)
      .attach('file', PNG, 'photo.png')
      .expect(403);
  });

  it('photo : un fichier qui n’est pas une image est refusé', async () => {
    const problem = await report();
    await as(tokens.magasinier)
      .post(`/api/problems/${problem.id}/photo`)
      .attach('file', Buffer.from('MZ ceci est un exécutable'), 'photo.jpg')
      .expect(422);
    // Sans photo, la route de lecture répond 404 et non une erreur technique.
    await as(tokens.magasinier)
      .get(`/api/problems/${problem.id}/photo`)
      .expect(404);
  });

  it('sans token : refusé', async () => {
    await request(server).get('/api/problems').expect(401);
  });
});
