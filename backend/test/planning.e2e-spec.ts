import { randomUUID } from 'crypto';
import * as request from 'supertest';
import { RoleCode } from '../src/common/auth.decorators';
import { localDate } from '../src/common/document-number';
import { PrismaService } from '../src/prisma/prisma.service';
import { createE2eApp, createTestUser, E2eApp } from './helpers/e2e-app';

/// Planning hebdomadaire (P0 n°10, spec §23).
///
/// Éprouvé en priorité : l'ADMIN planifie seul ; chaque membre ne voit et
/// n'exécute QUE ses tâches ; `EN_RETARD` est CALCULÉ à partir du lendemain de
/// l'échéance (même règle que les ventes à crédit) ; une tâche close ne se
/// réécrit pas.
describe('Planning (e2e)', () => {
  let e2e: E2eApp;
  let prisma: PrismaService;
  let server: E2eApp['server'];

  const suffix = Date.now();
  const PASSWORD = 'MotDePasseTemp1!';
  const userIds: string[] = [];
  const ids: Record<string, string> = {};
  const tokens: Record<string, string> = {};

  /// Jour civil local décalé de `offset` jours (0 = aujourd'hui à Alger).
  const day = (offset = 0) =>
    localDate(new Date(Date.now() + offset * 24 * 3600 * 1000));

  const as = (token: string) => ({
    get: (url: string) =>
      request(server).get(url).set('Authorization', `Bearer ${token}`),
    post: (url: string) =>
      request(server).post(url).set('Authorization', `Bearer ${token}`),
    patch: (url: string) =>
      request(server).patch(url).set('Authorization', `Bearer ${token}`),
    delete: (url: string) =>
      request(server).delete(url).set('Authorization', `Bearer ${token}`),
  });

  /// Tâche créée par l'admin pour `assignee` (le vendeur par défaut).
  const task = async (assignee = 'vendeur', extra: object = {}) =>
    (
      await as(tokens.admin)
        .post('/api/planning-tasks')
        .send({
          title: `Compter les câbles ${randomUUID().slice(0, 6)}`,
          type: 'COMPTAGE',
          assignedToId: ids[assignee],
          scheduledFor: day(0),
          dueDate: day(2),
          zone: 'Zone A',
          ...extra,
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
    ] as const) {
      const email = `e2e-planning-${key}-${suffix}@test.local`;
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
    const disabled = await createTestUser(prisma, {
      email: `e2e-planning-inactif-${suffix}@test.local`,
      password: PASSWORD,
      roles: [RoleCode.VENDEUR],
      isActive: false,
    });
    userIds.push(disabled.id);
    ids.inactif = disabled.id;
  });

  afterAll(async () => {
    await prisma.auditLog.deleteMany({ where: { userId: { in: userIds } } });
    await prisma.planningTask.deleteMany({
      where: {
        OR: [
          { assignedToId: { in: userIds } },
          { createdById: { in: userIds } },
        ],
      },
    });
    await prisma.user.deleteMany({ where: { id: { in: userIds } } });
    await e2e.app.close();
  });

  it('cycle complet : l’admin planifie, le membre démarre puis termine avec son résultat', async () => {
    const created = await task('vendeur');
    expect(created).toMatchObject({
      status: 'A_FAIRE',
      isLate: false,
      assignedToId: ids.vendeur,
      scheduledFor: day(0),
      dueDate: day(2),
    });

    const started = (
      await as(tokens.vendeur)
        .post(`/api/planning-tasks/${created.id}/start`)
        .expect(200)
    ).body;
    expect(started.status).toBe('EN_COURS');

    const done = (
      await as(tokens.vendeur)
        .post(`/api/planning-tasks/${created.id}/complete`)
        .send({ result: '120 m comptés, conforme', comment: 'RAS' })
        .expect(200)
    ).body;
    expect(done).toMatchObject({
      status: 'TERMINEE',
      result: '120 m comptés, conforme',
      comment: 'RAS',
      isLate: false,
    });
    expect(done.completedAt).not.toBeNull();
  });

  it('une tâche se termine sans résultat : refusé', async () => {
    const created = await task('vendeur');
    await as(tokens.vendeur)
      .post(`/api/planning-tasks/${created.id}/complete`)
      .send({})
      .expect(400);
    await as(tokens.vendeur)
      .post(`/api/planning-tasks/${created.id}/complete`)
      .send({ result: '  ' })
      .expect(400);
  });

  it('chacun ne voit QUE ses tâches ; celle d’un collègue est introuvable', async () => {
    const forMagasinier = await task('magasinier');

    // Le vendeur ne la voit ni dans la liste, ni en détail (404, pas 403 :
    // on ne confirme même pas qu'elle existe).
    const list = (
      await as(tokens.vendeur).get('/api/planning-tasks?limit=200').expect(200)
    ).body;
    expect(
      list.data.every(
        (t: { assignedToId: string }) => t.assignedToId === ids.vendeur,
      ),
    ).toBe(true);
    await as(tokens.vendeur)
      .get(`/api/planning-tasks/${forMagasinier.id}`)
      .expect(404);

    // Même en demandant explicitement les tâches d'un autre : ignoré.
    const forged = (
      await as(tokens.vendeur)
        .get(`/api/planning-tasks?assignedToId=${ids.magasinier}&limit=200`)
        .expect(200)
    ).body;
    expect(
      forged.data.some((t: { id: string }) => t.id === forMagasinier.id),
    ).toBe(false);

    // Et il ne peut ni la démarrer, ni la terminer.
    await as(tokens.vendeur)
      .post(`/api/planning-tasks/${forMagasinier.id}/start`)
      .expect(404);
    await as(tokens.vendeur)
      .post(`/api/planning-tasks/${forMagasinier.id}/complete`)
      .send({ result: 'Fait' })
      .expect(404);

    // L'admin, lui, voit le travail d'un membre précis.
    const byMember = (
      await as(tokens.admin)
        .get(`/api/planning-tasks?assignedToId=${ids.magasinier}&limit=200`)
        .expect(200)
    ).body;
    expect(
      byMember.data.some((t: { id: string }) => t.id === forMagasinier.id),
    ).toBe(true);
  });

  it('seul l’ADMIN planifie, modifie et supprime', async () => {
    const created = await task('vendeur');
    for (const key of ['vendeur', 'magasinier']) {
      await as(tokens[key])
        .post('/api/planning-tasks')
        .send({
          title: 'Auto-planifiée',
          type: 'AUTRE',
          assignedToId: ids[key],
          scheduledFor: day(0),
          dueDate: day(1),
        })
        .expect(403);
      await as(tokens[key])
        .patch(`/api/planning-tasks/${created.id}`)
        .send({ title: 'Renommée' })
        .expect(403);
      await as(tokens[key])
        .delete(`/api/planning-tasks/${created.id}`)
        .expect(403);
    }
  });

  it('EN RETARD : calculé à partir du LENDEMAIN de l’échéance, jamais le jour même', async () => {
    // L'API refuse une échéance passée : la tâche en retard est posée en base,
    // comme elle le serait après quelques jours sans être faite.
    const late = await prisma.planningTask.create({
      data: {
        title: 'Réception oubliée',
        type: 'RECEPTION',
        assignedToId: ids.vendeur,
        createdById: ids.admin,
        scheduledFor: new Date(`${day(-3)}T00:00:00.000Z`),
        dueDate: new Date(`${day(-1)}T00:00:00.000Z`),
      },
    });
    const dueToday = await task('vendeur', { dueDate: day(0) });

    expect(
      (
        await as(tokens.vendeur)
          .get(`/api/planning-tasks/${late.id}`)
          .expect(200)
      ).body.isLate,
    ).toBe(true);
    // Due AUJOURD'HUI : pas encore en retard (le bug évité sur les ventes).
    expect(dueToday.isLate).toBe(false);

    const lateOnly = (
      await as(tokens.admin)
        .get(
          `/api/planning-tasks?late=true&assignedToId=${ids.vendeur}&limit=200`,
        )
        .expect(200)
    ).body;
    const lateIds = lateOnly.data.map((t: { id: string }) => t.id);
    expect(lateIds).toContain(late.id);
    expect(lateIds).not.toContain(dueToday.id);

    // Terminée, elle n'est plus en retard, même si l'échéance est passée.
    const closed = (
      await as(tokens.vendeur)
        .post(`/api/planning-tasks/${late.id}/complete`)
        .send({ result: 'Faite avec un jour de retard' })
        .expect(200)
    ).body;
    expect(closed.isLate).toBe(false);
  });

  it('`status` et `late` se CUMULENT au lieu de s’écraser', async () => {
    const lateNotStarted = await prisma.planningTask.create({
      data: {
        title: 'Pas commencée, en retard',
        type: 'SAISIE',
        assignedToId: ids.magasinier,
        createdById: ids.admin,
        scheduledFor: new Date(`${day(-4)}T00:00:00.000Z`),
        dueDate: new Date(`${day(-2)}T00:00:00.000Z`),
      },
    });
    const lateStarted = await prisma.planningTask.create({
      data: {
        title: 'Commencée, en retard',
        type: 'SAISIE',
        status: 'EN_COURS',
        assignedToId: ids.magasinier,
        createdById: ids.admin,
        scheduledFor: new Date(`${day(-4)}T00:00:00.000Z`),
        dueDate: new Date(`${day(-2)}T00:00:00.000Z`),
      },
    });
    const found = (
      await as(tokens.admin)
        .get(
          `/api/planning-tasks?status=A_FAIRE&late=true&assignedToId=${ids.magasinier}&limit=200`,
        )
        .expect(200)
    ).body.data.map((t: { id: string }) => t.id);
    expect(found).toContain(lateNotStarted.id);
    expect(found).not.toContain(lateStarted.id);

    // Une tâche terminée n'est jamais en retard : demande contradictoire.
    const contradictory = await as(tokens.admin)
      .get('/api/planning-tasks?status=TERMINEE&late=true')
      .expect(400);
    expect(contradictory.body.code).toBe('VALIDATION_FAILED');
  });

  it('dates : échéance passée, fenêtre inversée, format libre — refusés', async () => {
    const base = {
      title: 'Tâche datée',
      type: 'AUTRE',
      assignedToId: ids.vendeur,
    };
    const past = await as(tokens.admin)
      .post('/api/planning-tasks')
      .send({ ...base, scheduledFor: day(-2), dueDate: day(-1) })
      .expect(422);
    expect(past.body.code).toBe('VALIDATION_FAILED');

    const inverted = await as(tokens.admin)
      .post('/api/planning-tasks')
      .send({ ...base, scheduledFor: day(3), dueDate: day(1) })
      .expect(422);
    expect(inverted.body.code).toBe('VALIDATION_FAILED');

    // Une heure n'a pas de sens pour un planning à la semaine ; une date
    // inexistante non plus.
    await as(tokens.admin)
      .post('/api/planning-tasks')
      .send({ ...base, scheduledFor: `${day(0)}T10:00:00Z`, dueDate: day(1) })
      .expect(400);
    await as(tokens.admin)
      .post('/api/planning-tasks')
      .send({ ...base, scheduledFor: day(0), dueDate: '2026-02-30' })
      .expect(400);
  });

  it('on ne confie pas une tâche à un compte désactivé', async () => {
    const refused = await as(tokens.admin)
      .post('/api/planning-tasks')
      .send({
        title: 'Pour personne',
        type: 'AUTRE',
        assignedToId: ids.inactif,
        scheduledFor: day(0),
        dueDate: day(1),
      })
      .expect(422);
    expect(refused.body.code).toBe('VALIDATION_FAILED');
  });

  it('l’admin réassigne et décale une tâche ; une tâche close ne se réécrit plus', async () => {
    const created = await task('vendeur');
    const moved = (
      await as(tokens.admin)
        .patch(`/api/planning-tasks/${created.id}`)
        .send({ assignedToId: ids.magasinier, dueDate: day(5) })
        .expect(200)
    ).body;
    expect(moved).toMatchObject({
      assignedToId: ids.magasinier,
      dueDate: day(5),
    });
    // Réassignée : le vendeur ne la voit plus, le magasinier si.
    await as(tokens.vendeur)
      .get(`/api/planning-tasks/${created.id}`)
      .expect(404);

    await as(tokens.magasinier)
      .post(`/api/planning-tasks/${created.id}/complete`)
      .send({ result: 'Fait' })
      .expect(200);
    const locked = await as(tokens.admin)
      .patch(`/api/planning-tasks/${created.id}`)
      .send({ title: 'Réécrite après coup' })
      .expect(409);
    expect(locked.body.code).toBe('INVALID_STATE_TRANSITION');

    // Et on ne la termine pas deux fois (le résultat ne s'écrase pas).
    await as(tokens.magasinier)
      .post(`/api/planning-tasks/${created.id}/complete`)
      .send({ result: 'Autre résultat' })
      .expect(409);
  });

  it('suppression : seulement tant que personne n’a commencé', async () => {
    const fresh = await task('vendeur');
    await as(tokens.admin)
      .delete(`/api/planning-tasks/${fresh.id}`)
      .expect(204);
    await as(tokens.admin).get(`/api/planning-tasks/${fresh.id}`).expect(404);

    const started = await task('vendeur');
    await as(tokens.vendeur)
      .post(`/api/planning-tasks/${started.id}/start`)
      .expect(200);
    const refused = await as(tokens.admin)
      .delete(`/api/planning-tasks/${started.id}`)
      .expect(409);
    expect(refused.body.code).toBe('INVALID_STATE_TRANSITION');
  });

  it('suppression et fin SIMULTANÉES : un seul geste passe', async () => {
    const created = await task('vendeur');
    const [removed, completed] = await Promise.all([
      as(tokens.admin).delete(`/api/planning-tasks/${created.id}`),
      as(tokens.vendeur)
        .post(`/api/planning-tasks/${created.id}/complete`)
        .send({ result: 'Fait' }),
    ]);
    // Soit la tâche est supprimée (et la fin échoue), soit elle est terminée
    // (et la suppression est refusée). Jamais une fin sur une tâche effacée.
    const outcome = [removed.status, completed.status].sort();
    expect([
      [204, 404],
      [200, 409],
    ]).toContainEqual(outcome);
  });

  it('renvoi du même formulaire (même id) : une seule tâche', async () => {
    const id = randomUUID();
    const payload = {
      id,
      title: 'Préparer la commande Benali',
      type: 'PREPARATION',
      assignedToId: ids.magasinier,
      scheduledFor: day(0),
      dueDate: day(1),
    };
    await as(tokens.admin)
      .post('/api/planning-tasks')
      .send(payload)
      .expect(201);
    const again = (
      await as(tokens.admin)
        .post('/api/planning-tasks')
        .send(payload)
        .expect(201)
    ).body;
    expect(again.id).toBe(id);
    expect(await prisma.planningTask.count({ where: { id } })).toBe(1);
  });

  it('une tâche EN RETARD se réassigne sans toucher à son échéance passée', async () => {
    // L'usage principal d'une tâche en retard : la confier à quelqu'un d'autre.
    // Son échéance est passée ; tant qu'on ne la CHANGE pas, elle n'est pas
    // revérifiée (revue du 2026-09-21, bloquant B1).
    const late = await prisma.planningTask.create({
      data: {
        title: 'En retard, à réassigner',
        type: 'SAISIE',
        assignedToId: ids.vendeur,
        createdById: ids.admin,
        scheduledFor: new Date(`${day(-3)}T00:00:00.000Z`),
        dueDate: new Date(`${day(-1)}T00:00:00.000Z`),
      },
    });
    const moved = (
      await as(tokens.admin)
        .patch(`/api/planning-tasks/${late.id}`)
        .send({ assignedToId: ids.magasinier })
        .expect(200)
    ).body;
    expect(moved).toMatchObject({ assignedToId: ids.magasinier, isLate: true });

    // Mais on ne la REPOUSSE pas dans le passé.
    await as(tokens.admin)
      .patch(`/api/planning-tasks/${late.id}`)
      .send({ dueDate: day(-2) })
      .expect(422);
  });

  it('réassignée : l’ancien titulaire ne la voit ni ne la termine plus', async () => {
    const created = await task('vendeur');
    await as(tokens.admin)
      .patch(`/api/planning-tasks/${created.id}`)
      .send({ assignedToId: ids.magasinier })
      .expect(200);
    await as(tokens.vendeur)
      .post(`/api/planning-tasks/${created.id}/complete`)
      .send({ result: 'Fait par l’ancien titulaire' })
      .expect(404);
    const still = await prisma.planningTask.findUniqueOrThrow({
      where: { id: created.id },
    });
    expect(still.status).toBe('A_FAIRE');
    expect(still.result).toBeNull();
  });

  it('tâche SUPPRIMÉE : la terminer répond 404, pas « déjà terminée »', async () => {
    const created = await task('vendeur');
    await as(tokens.admin)
      .delete(`/api/planning-tasks/${created.id}`)
      .expect(204);
    await as(tokens.vendeur)
      .post(`/api/planning-tasks/${created.id}/complete`)
      .send({ result: 'Fait' })
      .expect(404);
    await as(tokens.vendeur)
      .post(`/api/planning-tasks/${created.id}/start`)
      .expect(404);
  });

  it('démarrer deux fois : la seconde rend l’état atteint, sans erreur', async () => {
    const created = await task('vendeur');
    await as(tokens.vendeur)
      .post(`/api/planning-tasks/${created.id}/start`)
      .expect(200);
    const again = (
      await as(tokens.vendeur)
        .post(`/api/planning-tasks/${created.id}/start`)
        .expect(200)
    ).body;
    expect(again.status).toBe('EN_COURS');
  });

  it('vue de travail : `open` écarte les tâches closes, et ne se cumule pas avec TERMINEE', async () => {
    const open = await task('magasinier');
    const closed = await task('magasinier');
    await as(tokens.magasinier)
      .post(`/api/planning-tasks/${closed.id}/complete`)
      .send({ result: 'Fait' })
      .expect(200);
    const listed = (
      await as(tokens.magasinier)
        .get('/api/planning-tasks?open=true&limit=200')
        .expect(200)
    ).body.data.map((t: { id: string }) => t.id);
    expect(listed).toContain(open.id);
    expect(listed).not.toContain(closed.id);

    await as(tokens.admin)
      .get('/api/planning-tasks?open=true&status=TERMINEE')
      .expect(400);
    // Les tâches closes, les plus récentes d'abord.
    await as(tokens.magasinier)
      .get('/api/planning-tasks?status=TERMINEE&sort=completedAt:desc')
      .expect(200);
  });

  it('même id, AUTRE contenu : 409 ; `id: null` : 400, jamais 500', async () => {
    const id = randomUUID();
    const payload = {
      id,
      title: 'Préparer la commande Ould',
      type: 'PREPARATION',
      assignedToId: ids.magasinier,
      scheduledFor: day(0),
      dueDate: day(1),
    };
    await as(tokens.admin)
      .post('/api/planning-tasks')
      .send(payload)
      .expect(201);
    const conflict = await as(tokens.admin)
      .post('/api/planning-tasks')
      .send({ ...payload, title: 'Autre chose' })
      .expect(409);
    expect(conflict.body.code).toBe('CONFLICT');

    await as(tokens.admin)
      .post('/api/planning-tasks')
      .send({ ...payload, id: null })
      .expect(400);
  });

  it('l’ADMIN qui termine la tâche d’un autre laisse une trace — pas le membre', async () => {
    const byAdmin = await task('vendeur');
    await as(tokens.admin)
      .post(`/api/planning-tasks/${byAdmin.id}/complete`)
      .send({ result: 'Constaté par l’admin' })
      .expect(200);
    const trail = await prisma.auditLog.findMany({
      where: { entityType: 'PlanningTask', entityId: byAdmin.id },
      orderBy: [{ createdAt: 'asc' }, { id: 'asc' }],
    });
    const last = trail[trail.length - 1];
    expect(last.userId).toBe(ids.admin);
    expect(last.newValue).toMatchObject({
      status: 'TERMINEE',
      result: 'Constaté par l’admin',
      onBehalfOf: ids.vendeur,
    });
  });

  it('un PATCH qui ne change rien n’écrit pas de trace', async () => {
    const created = await task('vendeur');
    await as(tokens.admin)
      .patch(`/api/planning-tasks/${created.id}`)
      .send({})
      .expect(200);
    const trail = await prisma.auditLog.count({
      where: { entityType: 'PlanningTask', entityId: created.id },
    });
    expect(trail).toBe(1); // la seule création
  });

  it('audit : les gestes de l’ADMIN y sont, le travail courant du membre non', async () => {
    const created = await task('vendeur');
    await as(tokens.admin)
      .patch(`/api/planning-tasks/${created.id}`)
      .send({ title: 'Compter les câbles — rayon 3' })
      .expect(200);
    await as(tokens.vendeur)
      .post(`/api/planning-tasks/${created.id}/start`)
      .expect(200);
    await as(tokens.vendeur)
      .post(`/api/planning-tasks/${created.id}/complete`)
      .send({ result: 'Fait' })
      .expect(200);

    const trail = await prisma.auditLog.findMany({
      where: { entityType: 'PlanningTask', entityId: created.id },
      orderBy: [{ createdAt: 'asc' }, { id: 'asc' }],
    });
    expect(trail.map((entry) => entry.action)).toEqual(['CREATE', 'UPDATE']);
    expect(trail.every((entry) => entry.userId === ids.admin)).toBe(true);
  });
});
