import * as request from 'supertest';
import { RoleCode } from '../src/common/auth.decorators';
import { createE2eApp, createTestUser, E2eApp } from './helpers/e2e-app';

/// Audit I1 + M5 : en production, Traefik est le seul pair TCP du backend.
/// Sans `trust proxy`, tous les clients partagent le même compteur anti-brute-force
/// (un anonyme bloque tout le magasin) et l'audit trace l'IP du proxy.
describe('Durcissement HTTP (e2e)', () => {
  const suffix = Date.now();
  const PASSWORD = 'MotDePasseTemp1!';
  const saved = { ...process.env };

  const restoreEnv = () => {
    for (const name of [
      'TRUST_PROXY_HOPS',
      'AUTH_LOGIN_LIMIT',
      'AUTH_CHANGE_PASSWORD_LIMIT',
    ]) {
      if (saved[name] === undefined) delete process.env[name];
      else process.env[name] = saved[name];
    }
  };

  const cleanup = async (e2e: E2eApp, ids: string[]) => {
    await e2e.prisma.auditLog.deleteMany({
      where: { OR: [{ entityId: { in: ids } }, { userId: { in: ids } }] },
    });
    await e2e.prisma.user.deleteMany({ where: { id: { in: ids } } });
    await e2e.app.close();
  };

  describe('derrière un reverse-proxy déclaré (TRUST_PROXY_HOPS=1)', () => {
    let e2e: E2eApp;
    const ids: string[] = [];
    const adminEmail = `e2e-proxy-admin-${suffix}@test.local`;
    const vendeurEmail = `e2e-proxy-vendeur-${suffix}@test.local`;

    const loginFrom = (ip: string, identifier: string, password: string) =>
      request(e2e.server)
        .post('/api/auth/login')
        .set('X-Forwarded-For', ip)
        .send({ identifier, password });

    beforeAll(async () => {
      process.env.TRUST_PROXY_HOPS = '1';
      // Limites resserrées : lues à CHAQUE requête, elles s'appliquent tout de suite.
      process.env.AUTH_LOGIN_LIMIT = '3';
      process.env.AUTH_CHANGE_PASSWORD_LIMIT = '2';
      e2e = await createE2eApp();
      for (const [email, role] of [
        [adminEmail, RoleCode.ADMIN],
        [vendeurEmail, RoleCode.VENDEUR],
      ] as const) {
        ids.push(
          (
            await createTestUser(e2e.prisma, {
              email,
              password: PASSWORD,
              roles: [role],
            })
          ).id,
        );
      }
    });

    afterAll(async () => {
      restoreEnv();
      await cleanup(e2e, ids);
    });

    it('l’audit trace l’IP réelle du client, pas celle du proxy', async () => {
      const session = await loginFrom('203.0.113.7', adminEmail, PASSWORD);
      const created = await request(e2e.server)
        .post('/api/users')
        .set('X-Forwarded-For', '203.0.113.7')
        .set('Authorization', `Bearer ${session.body.accessToken}`)
        .send({
          email: `e2e-proxy-cree-${suffix}@test.local`,
          fullName: 'Créé derrière le proxy',
          temporaryPassword: PASSWORD,
          roles: [RoleCode.VENDEUR],
        })
        .expect(201);
      ids.push(created.body.id);

      const entry = await e2e.prisma.auditLog.findFirstOrThrow({
        where: { entityType: 'User', entityId: created.body.id },
      });
      expect(entry.ipAddress).toBe('203.0.113.7');
    });

    it('le quota de connexion est compté PAR client : un client bloqué n’en bloque pas un autre', async () => {
      for (let attempt = 1; attempt <= 3; attempt++) {
        expect(
          (await loginFrom('198.51.100.1', vendeurEmail, 'mauvais')).status,
        ).toBe(401);
      }

      const blocked = await loginFrom('198.51.100.1', vendeurEmail, 'mauvais');
      expect(blocked.status).toBe(429);
      expect(blocked.body.code).toBe('RATE_LIMITED');

      // Un autre poste du magasin n'est pas puni pour l'attaquant.
      expect(
        (await loginFrom('198.51.100.2', vendeurEmail, PASSWORD)).status,
      ).toBe(200);
    });

    it('le changement de mot de passe a son propre quota (anti-devinette)', async () => {
      const session = await loginFrom('192.0.2.10', vendeurEmail, PASSWORD);
      const attempt = () =>
        request(e2e.server)
          .post('/api/auth/change-password')
          .set('X-Forwarded-For', '192.0.2.10')
          .set('Authorization', `Bearer ${session.body.accessToken}`)
          .send({
            currentPassword: 'devinette',
            newPassword: 'NouveauMotDePasse1!',
          });

      expect((await attempt()).status).toBe(403);
      expect((await attempt()).status).toBe(403);
      const blocked = await attempt();
      expect(blocked.status).toBe(429);
      expect(blocked.body.code).toBe('RATE_LIMITED');
    });
  });

  describe('sans proxy déclaré (défaut)', () => {
    let e2e: E2eApp;
    const ids: string[] = [];
    const adminEmail = `e2e-noproxy-admin-${suffix}@test.local`;

    beforeAll(async () => {
      delete process.env.TRUST_PROXY_HOPS;
      e2e = await createE2eApp();
      ids.push(
        (
          await createTestUser(e2e.prisma, {
            email: adminEmail,
            password: PASSWORD,
            roles: [RoleCode.ADMIN],
          })
        ).id,
      );
    });

    afterAll(async () => {
      restoreEnv();
      await cleanup(e2e, ids);
    });

    it('un X-Forwarded-For forgé par le client est ignoré', async () => {
      const session = await request(e2e.server)
        .post('/api/auth/login')
        .send({ identifier: adminEmail, password: PASSWORD });
      const created = await request(e2e.server)
        .post('/api/users')
        .set('X-Forwarded-For', '6.6.6.6')
        .set('Authorization', `Bearer ${session.body.accessToken}`)
        .send({
          email: `e2e-noproxy-cree-${suffix}@test.local`,
          fullName: 'IP forgée',
          temporaryPassword: PASSWORD,
          roles: [RoleCode.VENDEUR],
        })
        .expect(201);
      ids.push(created.body.id);

      const entry = await e2e.prisma.auditLog.findFirstOrThrow({
        where: { entityType: 'User', entityId: created.body.id },
      });
      expect(entry.ipAddress).not.toBe('6.6.6.6');
      expect(entry.ipAddress).toBeTruthy();
    });
  });
});
