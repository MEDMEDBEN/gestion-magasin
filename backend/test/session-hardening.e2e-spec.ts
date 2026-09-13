import * as request from 'supertest';
import { RoleCode } from '../src/common/auth.decorators';
import { createE2eApp, createTestUser, E2eApp } from './helpers/e2e-app';

/// Tests dédiés aux correctifs du 2ᵉ tour d'audit sécurité (commit c3333c7) :
/// N1 session liée au token · N2 UUID canonique · N3 logout « tous appareils »
/// N4 compare-and-swap du changement de mot de passe · N10 quota par compte.
describe('Durcissement des sessions — contre-audit (e2e)', () => {
  let ctx: E2eApp;
  const suffix = Date.now();
  const PASSWORD = 'MotDePasseSolide1!';
  const created: string[] = [];

  let adminB: { id: string; email: string; token: string };

  const login = (identifier: string, password = PASSWORD) =>
    request(ctx.server).post('/api/auth/login').send({ identifier, password });

  /// Un admin de test, déjà connecté.
  async function newAdmin(tag: string) {
    const email = `e2e-sess-${tag}-${suffix}@test.local`;
    const { id } = await createTestUser(ctx.prisma, {
      email,
      password: PASSWORD,
      roles: [RoleCode.ADMIN],
    });
    created.push(id);
    const res = await login(email);
    expect(res.status).toBe(200);
    return {
      id,
      email,
      token: res.body.accessToken as string,
      refresh: res.body.refreshToken as string,
    };
  }

  const listUsers = (token: string) =>
    request(ctx.server).get('/api/users').set('Authorization', `Bearer ${token}`);

  const createUserWith = (token: string, tag: string) =>
    request(ctx.server)
      .post('/api/users')
      .set('Authorization', `Bearer ${token}`)
      .send({
        email: `e2e-sess-new-${tag}-${suffix}@test.local`,
        fullName: 'Compte de secours',
        temporaryPassword: PASSWORD,
        roles: [RoleCode.ADMIN],
      });

  beforeAll(async () => {
    ctx = await createE2eApp();
    const b = await newAdmin('b');
    adminB = { id: b.id, email: b.email, token: b.token };
  });

  afterAll(async () => {
    const extra = await ctx.prisma.user.findMany({
      where: { email: { startsWith: 'e2e-sess-new-' } },
      select: { id: true },
    });
    const ids = [...created, ...extra.map((u) => u.id)];
    await ctx.prisma.auditLog.deleteMany({ where: { entityId: { in: ids } } });
    await ctx.prisma.auditLog.deleteMany({ where: { userId: { in: ids } } });
    await ctx.prisma.user.deleteMany({ where: { id: { in: ids } } });
    await ctx.app.close();
  });

  describe('N1 — un ancien access token perd l’accès à la gestion des comptes', () => {
    it('après révocation des sessions par un autre admin : 401 en lecture ET en écriture', async () => {
      const a = await newAdmin('n1-revoke');
      await request(ctx.server)
        .post(`/api/users/${a.id}/revoke-sessions`)
        .set('Authorization', `Bearer ${adminB.token}`)
        .expect(200);

      const read = await listUsers(a.token);
      expect(read.status).toBe(401);
      expect(read.body.code).toBe('ACCESS_TOKEN_INVALID');

      // Le cas grave : un voleur ne peut plus se créer un admin de secours.
      const write = await createUserWith(a.token, 'revoke');
      expect(write.status).toBe(401);
      expect(write.body.code).toBe('ACCESS_TOKEN_INVALID');
    });

    it('après changement de son mot de passe : l’ancien token est refusé', async () => {
      const a = await newAdmin('n1-change');
      await request(ctx.server)
        .post('/api/auth/change-password')
        .set('Authorization', `Bearer ${a.token}`)
        .send({ currentPassword: PASSWORD, newPassword: 'NouveauSolide2!' })
        .expect(200);

      const res = await createUserWith(a.token, 'change');
      expect(res.status).toBe(401);
      expect(res.body.code).toBe('ACCESS_TOKEN_INVALID');
    });

    it('après « déconnecter tous mes appareils » : l’ancien token est refusé', async () => {
      const a = await newAdmin('n1-all');
      await request(ctx.server)
        .post('/api/auth/logout')
        .send({ refreshToken: a.refresh, allDevices: true })
        .expect(200);

      const res = await listUsers(a.token);
      expect(res.status).toBe(401);
      expect(res.body.code).toBe('ACCESS_TOKEN_INVALID');
    });

    it('après rotation du refresh : l’access token de l’ancienne session est refusé', async () => {
      const a = await newAdmin('n1-rotate');
      const rotated = await request(ctx.server)
        .post('/api/auth/refresh')
        .send({ refreshToken: a.refresh })
        .expect(200);

      expect((await listUsers(a.token)).status).toBe(401);
      // Le token neuf, lui, fonctionne.
      expect((await listUsers(rotated.body.accessToken)).status).toBe(200);
    });

    it('un reset commité en base impose le changement IMMÉDIATEMENT (403), sans attendre le token', async () => {
      const a = await newAdmin('n1-must');
      // Posé en base sans révoquer la session : seule la relecture en base peut le voir.
      await ctx.prisma.user.update({
        where: { id: a.id },
        data: { mustChangePassword: true },
      });

      const res = await listUsers(a.token);
      expect(res.status).toBe(403);
      expect(res.body.code).toBe('PASSWORD_CHANGE_REQUIRED');
    });

    it('après reset par un autre admin puis reconnexion : 403 PASSWORD_CHANGE_REQUIRED', async () => {
      const a = await newAdmin('n1-reset');
      await request(ctx.server)
        .post(`/api/users/${a.id}/reset-password`)
        .set('Authorization', `Bearer ${adminB.token}`)
        .send({ temporaryPassword: 'Temporaire3!' })
        .expect(200);

      expect((await listUsers(a.token)).status).toBe(401);

      const relogin = await login(a.email, 'Temporaire3!');
      const res = await listUsers(relogin.body.accessToken);
      expect(res.status).toBe(403);
      expect(res.body.code).toBe('PASSWORD_CHANGE_REQUIRED');
    });
  });

  describe('N2 — l’interdiction de s’auto-modifier ne se contourne pas par la casse', () => {
    it('PATCH /users/<SON-ID-EN-MAJUSCULES> avec des rôles : 403', async () => {
      const a = await newAdmin('n2');
      const res = await request(ctx.server)
        .patch(`/api/users/${a.id.toUpperCase()}`)
        .set('Authorization', `Bearer ${a.token}`)
        .send({ roles: [RoleCode.ADMIN, RoleCode.VENDEUR] });

      expect(res.status).toBe(403);
      expect(res.body.code).toBe('SELF_MODIFICATION_FORBIDDEN');
    });
  });

  describe('N3 — logout « tous appareils » exige une session valide', () => {
    it('token révoqué : 401 REFRESH_TOKEN_REVOKED, sessions fermées et vol TRACÉ', async () => {
      const a = await newAdmin('n3-revoked');
      // Rotation : l'ancien refresh devient révoqué ; on garde une session vivante.
      const rotated = await request(ctx.server)
        .post('/api/auth/refresh')
        .send({ refreshToken: a.refresh })
        .expect(200);

      const res = await request(ctx.server)
        .post('/api/auth/logout')
        .send({ refreshToken: a.refresh, allDevices: true });

      expect(res.status).toBe(401);
      expect(res.body.code).toBe('REFRESH_TOKEN_REVOKED');
      // Réaction de rejeu : même la session neuve est tombée.
      expect((await listUsers(rotated.body.accessToken)).status).toBe(401);

      const trace = await ctx.prisma.auditLog.findFirst({
        where: { entityId: a.id, newValue: { path: ['operation'], equals: 'REFRESH_TOKEN_REUSE_DETECTED' } },
      });
      expect(trace).not.toBeNull();
      // L'action n'est PAS attribuée à la victime.
      expect(trace!.userId).toBeNull();
    });

    it('token inconnu : 401 REFRESH_TOKEN_INVALID', async () => {
      const res = await request(ctx.server)
        .post('/api/auth/logout')
        .send({ refreshToken: 'f'.repeat(64), allDevices: true });

      expect(res.status).toBe(401);
      expect(res.body.code).toBe('REFRESH_TOKEN_INVALID');
    });

    it('token expiré : 401 REFRESH_TOKEN_EXPIRED, aucune session fermée', async () => {
      const a = await newAdmin('n3-expired');
      const other = await login(a.email);
      // Seule la session du premier refresh expire.
      const { createHash } = await import('node:crypto');
      await ctx.prisma.refreshToken.update({
        where: { tokenHash: createHash('sha256').update(a.refresh).digest('hex') },
        data: { expiresAt: new Date(Date.now() - 1000) },
      });

      const res = await request(ctx.server)
        .post('/api/auth/logout')
        .send({ refreshToken: a.refresh, allDevices: true });

      expect(res.status).toBe(401);
      expect(res.body.code).toBe('REFRESH_TOKEN_EXPIRED');
      // L'autre session n'a PAS été fermée.
      expect((await listUsers(other.body.accessToken)).status).toBe(200);
    });
  });

  describe('N4 — le changement de mot de passe ne peut pas écraser un reset concurrent', () => {
    it('reset commité pendant le hachage : 409, le mot de passe temporaire reste valide', async () => {
      const a = await newAdmin('n4');
      const { hashPassword } = await import('../src/auth/password');
      const resetHash = await hashPassword('TemporaireAdmin4!');

      // Le reset de l'admin est commité juste avant la transaction du
      // changement : exactement la fenêtre de course visée.
      const original = ctx.prisma.$transaction.bind(ctx.prisma) as (...args: unknown[]) => unknown;
      const spy = jest
        .spyOn(ctx.prisma, '$transaction')
        .mockImplementationOnce((async (...args: unknown[]) => {
          await ctx.prisma.user.update({
            where: { id: a.id },
            data: { passwordHash: resetHash, mustChangePassword: true },
          });
          return original(...args);
        }) as never);

      try {
        const res = await request(ctx.server)
          .post('/api/auth/change-password')
          .set('Authorization', `Bearer ${a.token}`)
          .send({ currentPassword: PASSWORD, newPassword: 'MotDePasseAttaquant5!' });

        expect(res.status).toBe(409);
        expect(res.body.code).toBe('CONFLICT');
      } finally {
        spy.mockRestore();
      }

      // Le mot de passe de l'attaquant n'a PAS été écrit ; celui du reset tient.
      expect((await login(a.email, 'MotDePasseAttaquant5!')).status).toBe(401);
      expect((await login(a.email, 'TemporaireAdmin4!')).status).toBe(200);
    });
  });

  describe('N10 — le quota de connexion est compté par compte, pas par IP seule', () => {
    const previous = process.env.AUTH_LOGIN_LIMIT;

    beforeAll(() => {
      process.env.AUTH_LOGIN_LIMIT = '3';
    });

    afterAll(() => {
      if (previous === undefined) delete process.env.AUTH_LOGIN_LIMIT;
      else process.env.AUTH_LOGIN_LIMIT = previous;
    });

    it('3 échecs sur A bloquent A, mais B se connecte depuis la même IP', async () => {
      const victimEmail = `e2e-sess-quota-a-${suffix}@test.local`;
      const colleagueEmail = `e2e-sess-quota-b-${suffix}@test.local`;
      for (const email of [victimEmail, colleagueEmail]) {
        const { id } = await createTestUser(ctx.prisma, {
          email,
          password: PASSWORD,
          roles: [RoleCode.VENDEUR],
        });
        created.push(id);
      }

      for (let i = 0; i < 3; i++) {
        expect((await login(victimEmail, 'mauvais')).status).toBe(401);
      }
      const blocked = await login(victimEmail, 'mauvais');
      expect(blocked.status).toBe(429);
      expect(blocked.body.code).toBe('RATE_LIMITED');

      // Tous les postes du magasin sortent par la même IP : un collègue ne doit
      // pas être bloqué par les échecs de quelqu'un d'autre.
      expect((await login(colleagueEmail)).status).toBe(200);
    });
  });
});
