import * as request from 'supertest';
import { RoleCode } from '../src/common/auth.decorators';
import { PrismaService } from '../src/prisma/prisma.service';
import { createE2eApp, createTestUser, E2eApp } from './helpers/e2e-app';

/// Caisse (CLAUDE.md règle 12) : une session ouverte par compte, au magasin ;
/// clôture = rapport Z (attendu, compté, écart) ; chacun sa caisse.
describe('Caisse (e2e)', () => {
  let e2e: E2eApp;
  let prisma: PrismaService;
  let server: E2eApp['server'];

  const suffix = Date.now();
  const PASSWORD = 'MotDePasseTemp1!';
  const userIds: string[] = [];
  const tokens: Record<string, string> = {};
  let magasinId = '';
  let depotId = '';

  const as = (token: string) => ({
    get: (url: string) =>
      request(server).get(url).set('Authorization', `Bearer ${token}`),
    post: (url: string) =>
      request(server).post(url).set('Authorization', `Bearer ${token}`),
  });

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
      ['vendeur2', RoleCode.VENDEUR],
      ['vendeur3', RoleCode.VENDEUR],
      ['caissier', RoleCode.VENDEUR],
      ['veille', RoleCode.VENDEUR],
      ['magasinier', RoleCode.MAGASINIER],
    ] as const) {
      const email = `e2e-cash-${key}-${suffix}@test.local`;
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
    await prisma.auditLog.deleteMany({ where: { userId: { in: userIds } } });
    await prisma.cashMovement.deleteMany({
      where: { userId: { in: userIds } },
    });
    await prisma.cashSession.deleteMany({ where: { userId: { in: userIds } } });
    await prisma.user.deleteMany({ where: { id: { in: userIds } } });
    await e2e.app.close();
  });

  it('ouvrir, voir sa caisse, clôturer : rapport Z avec écart, puis plus rien d’ouvert', async () => {
    const opened = await as(tokens.vendeur)
      .post('/api/cash-sessions')
      .send({ locationId: magasinId, openingFloat: 500000 })
      .expect(201);
    expect(opened.body).toMatchObject({
      status: 'OUVERTE',
      openingFloat: 500000,
      currentAmount: 500000,
    });

    const current = await as(tokens.vendeur)
      .get('/api/cash-sessions/current')
      .expect(200);
    expect(current.body.id).toBe(opened.body.id);

    // Déjà une caisse ouverte : refus.
    const again = await as(tokens.vendeur)
      .post('/api/cash-sessions')
      .send({ locationId: magasinId, openingFloat: 0 })
      .expect(409);
    expect(again.body.code).toBe('CASH_SESSION_ALREADY_OPEN');

    const closed = await as(tokens.vendeur)
      .post(`/api/cash-sessions/${opened.body.id}/close`)
      .send({ countedAmount: 498000, note: 'Pièce manquante' })
      .expect(200);
    expect(closed.body).toMatchObject({
      status: 'CLOTUREE',
      expectedAmount: 500000,
      countedAmount: 498000,
      difference: -2000,
    });
    await as(tokens.vendeur)
      .post(`/api/cash-sessions/${opened.body.id}/close`)
      .send({ countedAmount: 1 })
      .expect(409);

    const none = await as(tokens.vendeur)
      .get('/api/cash-sessions/current')
      .expect(200);
    expect(none.body).toEqual({});
    const audit = await prisma.auditLog.findMany({
      where: { entityType: 'CashSession', entityId: opened.body.id },
      orderBy: { createdAt: 'asc' },
    });
    expect(audit.map((a) => a.action)).toEqual(['CREATE', 'VALIDATE']);
  });

  /// Décision MEDMEDBEN du 2026-10-08 : une caisse ne vit qu'un jour.
  it('caisse de la veille : plus de sortie, clôture auto non comptée, on rouvre', async () => {
    const opened = (
      await as(tokens.veille)
        .post('/api/cash-sessions')
        .send({ locationId: magasinId, openingFloat: 300000 })
        .expect(201)
    ).body as { id: string };
    // Ouverte « hier » (deux jours plus tôt, quel que soit le fuseau).
    await prisma.cashSession.update({
      where: { id: opened.id },
      data: { openedAt: new Date(Date.now() - 2 * 86_400_000) },
    });
    const out = await as(tokens.veille)
      .post(`/api/cash-sessions/${opened.id}/movements`)
      .send({ type: 'SORTIE', amount: 1000, note: 'Café' });
    expect(out.status).toBeGreaterThanOrEqual(400);

    const current = await as(tokens.veille)
      .get('/api/cash-sessions/current')
      .expect(200);
    expect(current.body).toEqual({});
    const closed = await prisma.cashSession.findUniqueOrThrow({
      where: { id: opened.id },
    });
    expect(closed).toMatchObject({
      status: 'CLOTUREE',
      expectedAmount: 300000,
      countedAmount: null,
      difference: null,
    });
    expect(closed.note).toContain('automatique');

    await as(tokens.veille)
      .post('/api/cash-sessions')
      .send({ locationId: magasinId, openingFloat: 250000 })
      .expect(201);
  });

  /// P1 bis n°21k : entrée, sortie, prélèvement — avec motif, jamais sous 0,
  /// rejouables sans double effet, comptés dans le rapport Z, audités.
  it('mouvements manuels : entrée, sortie, prélèvement, rapport Z juste', async () => {
    const session = (
      await as(tokens.caissier)
        .post('/api/cash-sessions')
        .send({ locationId: magasinId, openingFloat: 100000 })
        .expect(201)
    ).body as { id: string };
    const move = (token: string, body: object) =>
      as(token).post(`/api/cash-sessions/${session.id}/movements`).send(body);

    const key = '0192f3a0-0000-7000-8000-00000000c0de';
    const entree = {
      clientMutationId: key,
      type: 'ENTREE',
      amount: 20000,
      note: 'Monnaie',
    };
    const first = await move(tokens.caissier, entree).expect(200);
    expect(first.body.currentAmount).toBe(120000);
    // Réponse perdue, même clé : la caisse est rendue, rien n'est ajouté.
    const replay = await move(tokens.caissier, entree).expect(200);
    expect(replay.body.currentAmount).toBe(120000);
    // Même clé, autre montant : 409.
    await move(tokens.caissier, { ...entree, amount: 1 }).expect(409);

    await move(tokens.caissier, {
      type: 'SORTIE',
      amount: 15000,
      note: 'Achat ampoules atelier',
    }).expect(200);
    // Le tiroir ne descend jamais sous 0.
    const tooMuch = await move(tokens.caissier, {
      type: 'PRELEVEMENT',
      amount: 999999,
      note: 'Coffre',
    }).expect(422);
    expect(tooMuch.body.code).toBe('CASH_INSUFFICIENT');
    const after = await move(tokens.caissier, {
      type: 'PRELEVEMENT',
      amount: 50000,
      note: 'Dépôt banque',
    }).expect(200);
    // 1 000 + 200 − 150 − 500 = 550,00 DA dans le tiroir.
    expect(after.body.currentAmount).toBe(55000);

    // L'admin agit sur la caisse d'un vendeur (docs/permissions.md).
    await move(tokens.admin, {
      type: 'ENTREE',
      amount: 100,
      note: 'Appoint admin',
    }).expect(200);
    await move(tokens.caissier, {
      type: 'SORTIE',
      amount: 100,
      note: 'Rendu appoint',
    }).expect(200);
    // Le tiroir ne dépasse jamais le plafond d'un montant (sinon la clôture
    // échouerait : colonnes entières).
    await move(tokens.caissier, {
      type: 'ENTREE',
      amount: 2_000_000_000,
      note: 'Trop',
    }).expect(422);
    // Motif fait d'espaces : refusé comme vide.
    await move(tokens.caissier, {
      type: 'ENTREE',
      amount: 100,
      note: '   ',
    }).expect(400);

    // Motif obligatoire ; type inconnu refusé ; un collègue : 404.
    await move(tokens.caissier, {
      type: 'ENTREE',
      amount: 100,
      note: '',
    }).expect(400);
    await move(tokens.caissier, {
      type: 'VENTE_ESPECES',
      amount: 100,
      note: 'Non',
    }).expect(400);
    await move(tokens.vendeur2, {
      type: 'ENTREE',
      amount: 100,
      note: 'Autrui',
    }).expect(404);

    const closed = await as(tokens.caissier)
      .post(`/api/cash-sessions/${session.id}/close`)
      .send({ countedAmount: 55000 })
      .expect(200);
    expect(closed.body).toMatchObject({ expectedAmount: 55000, difference: 0 });
    // Le rapport Z MONTRE chaque mouvement : qui, combien, pourquoi (une
    // sortie fictive qui couvrirait un écart se voit).
    expect(closed.body.movements).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          type: 'PRELEVEMENT',
          amount: 50000,
          note: 'Dépôt banque',
        }),
        expect.objectContaining({ type: 'ENTREE', note: 'Appoint admin' }),
      ]),
    );
    const report = await as(tokens.admin)
      .get(`/api/cash-sessions/${session.id}/report`)
      .expect(200);
    expect(report.body.movements).toHaveLength(5);
    // Caisse clôturée : plus aucun mouvement.
    await move(tokens.caissier, {
      type: 'ENTREE',
      amount: 100,
      note: 'Tard',
    }).expect(409);

    const audit = await prisma.auditLog.count({
      where: {
        entityType: 'CashSession',
        entityId: session.id,
        action: 'UPDATE',
      },
    });
    expect(audit).toBe(5);
  });

  it('chacun sa caisse : un collègue ne la voit ni ne la clôture ; l’ADMIN voit le rapport', async () => {
    const opened = await as(tokens.vendeur2)
      .post('/api/cash-sessions')
      .send({ locationId: magasinId, openingFloat: 1000 })
      .expect(201);

    await as(tokens.vendeur3)
      .get(`/api/cash-sessions/${opened.body.id}/report`)
      .expect(404);
    await as(tokens.vendeur3)
      .post(`/api/cash-sessions/${opened.body.id}/close`)
      .send({ countedAmount: 0 })
      .expect(404);
    await as(tokens.admin)
      .get(`/api/cash-sessions/${opened.body.id}/report`)
      .expect(200);
  });

  it('caisse au dépôt → 422 ; MAGASINIER → 403 ; montants invalides → 400', async () => {
    await as(tokens.admin)
      .post('/api/cash-sessions')
      .send({ locationId: depotId, openingFloat: 0 })
      .expect(422);
    await as(tokens.magasinier)
      .post('/api/cash-sessions')
      .send({ locationId: magasinId, openingFloat: 0 })
      .expect(403);
    for (const openingFloat of [-1, 10.5, 3_000_000_000, '100']) {
      await as(tokens.admin)
        .post('/api/cash-sessions')
        .send({ locationId: magasinId, openingFloat })
        .expect(400);
    }
  });

  it('deux ouvertures simultanées du même compte : une seule caisse', async () => {
    const results = await Promise.all(
      [1, 2].map(() =>
        as(tokens.vendeur3)
          .post('/api/cash-sessions')
          .send({ locationId: magasinId, openingFloat: 0 }),
      ),
    );
    expect(results.map((r) => r.status).sort()).toEqual([201, 409]);
  });
});
