import * as request from 'supertest';
import { RoleCode } from '../src/common/auth.decorators';
import { PrismaService } from '../src/prisma/prisma.service';
import { createE2eApp, createTestUser, E2eApp } from './helpers/e2e-app';

/// Communication interne (P1 n°17, spec §25).
///
/// Éprouvé en priorité : un fil dont je ne suis pas participant N'EXISTE PAS
/// pour moi (l'admin compris) ; l'ouvrir vaut lecture ; un message prévient les
/// autres et eux seuls ; un fil clos ne se réécrit pas.
describe('Communication interne (e2e)', () => {
  let e2e: E2eApp;
  let prisma: PrismaService;
  let server: E2eApp['server'];

  const suffix = Date.now();
  const PASSWORD = 'MotDePasseTemp1!';
  const userIds: string[] = [];
  const ids: Record<string, string> = {};
  const tokens: Record<string, string> = {};

  const as = (token: string) => ({
    get: (url: string) =>
      request(server).get(url).set('Authorization', `Bearer ${token}`),
    post: (url: string) =>
      request(server).post(url).set('Authorization', `Bearer ${token}`),
  });

  /// Fil ouvert par le vendeur avec le magasinier.
  const openThread = async (
    who = 'vendeur',
    withWhom: string[] = ['magasinier'],
    subject = `Question dépôt ${Math.random().toString(36).slice(2, 7)}`,
  ) =>
    (
      await as(tokens[who])
        .post('/api/conversations')
        .send({
          subject,
          participantIds: withWhom.map((key) => ids[key]),
          body: 'Reste-t-il des câbles 2,5 mm² au dépôt ?',
        })
        .expect(201)
    ).body;

  beforeAll(async () => {
    e2e = await createE2eApp();
    prisma = e2e.prisma;
    server = e2e.server;
    for (const [key, role] of [
      ['admin', RoleCode.ADMIN],
      ['vendeur', RoleCode.VENDEUR],
      ['magasinier', RoleCode.MAGASINIER],
      ['tiers', RoleCode.VENDEUR],
    ] as const) {
      const email = `e2e-conv-${key}-${suffix}@test.local`;
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
    await prisma.message.deleteMany({ where: { authorId: { in: userIds } } });
    await prisma.conversationParticipant.deleteMany({
      where: { userId: { in: userIds } },
    });
    await prisma.conversation.deleteMany({
      where: { createdById: { in: userIds } },
    });
    await prisma.auditLog.deleteMany({ where: { userId: { in: userIds } } });
    await prisma.user.deleteMany({ where: { id: { in: userIds } } });
    await e2e.app.close();
  });

  it('ouvrir un fil : l’auteur en est participant, le premier message est là', async () => {
    const thread = await openThread();

    expect(
      thread.participants.map((p: { userId: string }) => p.userId).sort(),
    ).toEqual([ids.vendeur, ids.magasinier].sort());
    expect(thread.closedAt).toBeNull();

    const detail = (
      await as(tokens.magasinier)
        .get(`/api/conversations/${thread.id}`)
        .expect(200)
    ).body;
    expect(detail.messages).toHaveLength(1);
    expect(detail.messages[0].body).toContain('câbles 2,5 mm²');
    expect(detail.messages[0].authorName).toBeTruthy();
  });

  it('un fil sans autre participant que soi est refusé', async () => {
    await as(tokens.vendeur)
      .post('/api/conversations')
      .send({
        subject: 'Note pour moi',
        participantIds: [ids.vendeur],
        body: 'Penser à commander',
      })
      .expect(422);
  });

  it('un fil dont je ne fais pas partie N’EXISTE PAS, même pour l’admin', async () => {
    const thread = await openThread();

    // Le tiers et l'admin ne sont pas participants : 404, pas 403 — le refus
    // ne doit pas révéler que le fil existe.
    await as(tokens.tiers).get(`/api/conversations/${thread.id}`).expect(404);
    await as(tokens.admin).get(`/api/conversations/${thread.id}`).expect(404);
    // Ils ne peuvent pas non plus y écrire.
    await as(tokens.admin)
      .post(`/api/conversations/${thread.id}/messages`)
      .send({ body: 'Je passais par là' })
      .expect(404);
    // Et il n'apparaît pas dans leur liste.
    const liste = (await as(tokens.tiers).get('/api/conversations').expect(200))
      .body;
    expect(liste.data.map((c: { id: string }) => c.id)).not.toContain(
      thread.id,
    );
  });

  it('un message prévient les AUTRES participants, jamais son auteur', async () => {
    const thread = await openThread();
    const alerts = (userId: string) =>
      prisma.notification.count({
        where: { userId, operationId: thread.id, type: 'MESSAGE' },
      });

    // Le premier message a déjà prévenu le magasinier, pas le vendeur.
    expect(await alerts(ids.magasinier)).toBe(1);
    expect(await alerts(ids.vendeur)).toBe(0);
    expect(await alerts(ids.tiers)).toBe(0);

    await as(tokens.magasinier)
      .post(`/api/conversations/${thread.id}/messages`)
      .send({ body: 'Il en reste 3, je te les prépare.' })
      .expect(201);

    expect(await alerts(ids.vendeur)).toBe(1);
    expect(await alerts(ids.magasinier)).toBe(1);
  });

  it('les non-lus comptent les messages des AUTRES, et l’ouverture les solde', async () => {
    const thread = await openThread();

    const mine = async (who: string) => {
      const liste = (
        await as(tokens[who]).get('/api/conversations').expect(200)
      ).body;
      return liste.data.find((c: { id: string }) => c.id === thread.id);
    };

    // L'auteur a lu son propre message ; le destinataire a un non-lu.
    expect((await mine('vendeur')).unread).toBe(0);
    expect((await mine('magasinier')).unread).toBe(1);

    // Ouvrir le fil vaut lecture.
    await as(tokens.magasinier)
      .get(`/api/conversations/${thread.id}`)
      .expect(200);
    expect((await mine('magasinier')).unread).toBe(0);

    // Une réponse recrée un non-lu chez l'autre, pas chez son auteur.
    await as(tokens.magasinier)
      .post(`/api/conversations/${thread.id}/messages`)
      .send({ body: 'C’est prêt.' })
      .expect(201);
    expect((await mine('magasinier')).unread).toBe(0);
    expect((await mine('vendeur')).unread).toBe(1);
  });

  it('fil clos : plus de message, et il sort de la liste par défaut', async () => {
    const thread = await openThread();

    // Un participant qui n'en est pas l'auteur ne le clôt pas.
    await as(tokens.magasinier)
      .post(`/api/conversations/${thread.id}/close`)
      .expect(403);

    const closed = (
      await as(tokens.vendeur)
        .post(`/api/conversations/${thread.id}/close`)
        .expect(201)
    ).body;
    expect(closed.closedAt).not.toBeNull();

    await as(tokens.vendeur)
      .post(`/api/conversations/${thread.id}/messages`)
      .send({ body: 'Encore une chose' })
      .expect(409);

    const parDefaut = (
      await as(tokens.vendeur).get('/api/conversations').expect(200)
    ).body;
    expect(parDefaut.data.map((c: { id: string }) => c.id)).not.toContain(
      thread.id,
    );
    const avecClos = (
      await as(tokens.vendeur)
        .get('/api/conversations?includeClosed=true')
        .expect(200)
    ).body;
    expect(avecClos.data.map((c: { id: string }) => c.id)).toContain(thread.id);
  });

  it('un membre désactivé ne peut pas être ajouté à un fil', async () => {
    await prisma.user.update({
      where: { id: ids.tiers },
      data: { isActive: false },
    });

    await as(tokens.vendeur)
      .post('/api/conversations')
      .send({
        subject: 'Avec un compte fermé',
        participantIds: [ids.tiers],
        body: 'Bonjour',
      })
      .expect(422);

    await prisma.user.update({
      where: { id: ids.tiers },
      data: { isActive: true },
    });
  });

  it('sans token : refusé', async () => {
    await request(server).get('/api/conversations').expect(401);
  });

  /// C'est le magasinier qui a le plus besoin de poser une question, et
  /// `/users` lui est fermé : sans annuaire dédié, deux rôles sur trois ne
  /// pouvaient pas OUVRIR un fil (audit sécurité).
  it('les trois rôles ont un annuaire pour écrire, sans voir les comptes', async () => {
    for (const who of ['admin', 'vendeur', 'magasinier']) {
      const recipients = (
        await as(tokens[who]).get('/api/conversations/recipients').expect(200)
      ).body;

      expect(recipients.length).toBeGreaterThan(0);
      // Moi-même exclu : on n'écrit pas à soi.
      expect(recipients.map((r: { id: string }) => r.id)).not.toContain(
        ids[who],
      );
      // Identifiant et nom, RIEN d'autre : pas d'email, pas de rôle.
      expect(Object.keys(recipients[0]).sort()).toEqual(['fullName', 'id']);
    }
    // Et `/users` reste fermé aux non-admins.
    await as(tokens.magasinier).get('/api/users').expect(403);
  });

  it('un magasinier ouvre un fil de bout en bout', async () => {
    const thread = await openThread('magasinier', ['vendeur']);

    expect(thread.id).toBeTruthy();
    const detail = (
      await as(tokens.vendeur)
        .get(`/api/conversations/${thread.id}`)
        .expect(200)
    ).body;
    expect(detail.messages).toHaveLength(1);
  });
});
