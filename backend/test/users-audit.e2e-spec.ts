import * as request from 'supertest';
import { RoleCode } from '../src/common/auth.decorators';
import { PrismaService } from '../src/prisma/prisma.service';
import { UsersService } from '../src/users/users.service';
import {
  createE2eApp,
  createTestUser,
  E2eApp,
  failAuditInNextTransaction,
} from './helpers/e2e-app';

/// Gestion des comptes (ADMIN) : traçabilité (spec §24), atomicité (règles 3 et 7),
/// garde-fous d'administration (dernier admin, auto-modification, permissions
/// réservées) et accès relu en base (audit I4).
describe('Gestion des comptes (e2e)', () => {
  let e2e: E2eApp;
  let prisma: PrismaService;
  let server: E2eApp['server'];

  const suffix = Date.now();
  const adminEmail = `e2e-audit-admin-${suffix}@test.local`;
  const PASSWORD = 'MotDePasseTemp1!';

  let adminId = '';
  let adminToken = '';
  const createdIds: string[] = [];
  let counter = 0;

  const login = (identifier: string, password: string) =>
    request(server).post('/api/auth/login').send({ identifier, password });

  const as = (token: string) => ({
    get: (url: string) => request(server).get(url).set('Authorization', `Bearer ${token}`),
    post: (url: string) => request(server).post(url).set('Authorization', `Bearer ${token}`),
    patch: (url: string) => request(server).patch(url).set('Authorization', `Bearer ${token}`),
  });

  /// Entrées d'audit portant sur un compte donné, la plus récente d'abord.
  const auditFor = (entityId: string) =>
    prisma.auditLog.findMany({
      where: { entityType: 'User', entityId },
      orderBy: { createdAt: 'desc' },
    });

  const uniqueEmail = (label: string) => `e2e-audit-${label}-${suffix}-${++counter}@test.local`;

  /// Crée un compte via l'API et mémorise son id pour le nettoyage.
  const createUser = async (label: string, role: RoleCode = RoleCode.VENDEUR) => {
    const response = await as(adminToken)
      .post('/api/users')
      .send({
        email: uniqueEmail(label),
        fullName: `Compte ${label}`,
        temporaryPassword: PASSWORD,
        roles: [role],
      })
      .expect(201);
    createdIds.push(response.body.id);
    return response.body as { id: string; email: string };
  };

  /// Compte prêt à l'emploi (mot de passe déjà changé) + son access token.
  const sessionFor = async (label: string, roles: RoleCode[]) => {
    const email = uniqueEmail(label);
    const user = await createTestUser(prisma, { email, password: PASSWORD, roles });
    createdIds.push(user.id);
    const session = await login(email, PASSWORD);
    return { id: user.id, email, token: session.body.accessToken as string };
  };

  /// Neutralise temporairement les AUTRES admins actifs de la base de dev, pour
  /// placer le test dans la situation « un seul admin actif ». Restaure ensuite.
  const withOnlyTheseAdminsActive = async (keep: string[], body: () => Promise<void>) => {
    const others = await prisma.user.findMany({
      where: { isActive: true, roles: { some: { code: RoleCode.ADMIN } }, NOT: { id: { in: keep } } },
      select: { id: true },
    });
    const ids = others.map((u) => u.id);
    await prisma.user.updateMany({ where: { id: { in: ids } }, data: { isActive: false } });
    try {
      await body();
    } finally {
      await prisma.user.updateMany({ where: { id: { in: ids } }, data: { isActive: true } });
    }
  };

  beforeAll(async () => {
    e2e = await createE2eApp();
    prisma = e2e.prisma;
    server = e2e.server;

    const admin = await createTestUser(prisma, {
      email: adminEmail,
      password: PASSWORD,
      roles: [RoleCode.ADMIN],
      fullName: 'Admin Audit',
    });
    adminId = admin.id;
    createdIds.push(admin.id);
    adminToken = (await login(adminEmail, PASSWORD)).body.accessToken;
  });

  afterAll(async () => {
    await prisma.auditLog.deleteMany({
      where: { OR: [{ entityId: { in: createdIds } }, { userId: { in: createdIds } }] },
    });
    await prisma.user.deleteMany({ where: { id: { in: createdIds } } });
    await e2e.app.close();
  });

  afterEach(() => jest.restoreAllMocks());

  describe('traçabilité', () => {
    it('la création d’un compte est tracée, avec son auteur', async () => {
      const created = await createUser('new');

      const entries = await auditFor(created.id);
      expect(entries).toHaveLength(1);
      expect(entries[0].action).toBe('CREATE');
      expect(entries[0].entityType).toBe('User');
      // C'est bien l'ADMIN qui a agi, pas le compte créé.
      expect(entries[0].userId).toBe(adminId);
      expect(entries[0].ipAddress).toBeTruthy();
      expect(entries[0].newValue).toMatchObject({
        email: created.email,
        roles: ['VENDEUR'],
        isActive: true,
      });
    });

    it('la trace ne contient JAMAIS de mot de passe', async () => {
      const created = await createUser('secret');

      await as(adminToken)
        .post(`/api/users/${created.id}/reset-password`)
        .send({ temporaryPassword: 'UnAutreMotDePasse9!' })
        .expect(200);

      const dump = JSON.stringify(await auditFor(created.id));
      // Le journal est lisible par l'admin : il ne doit pas devenir une fuite.
      expect(dump).not.toContain(PASSWORD);
      expect(dump).not.toContain('UnAutreMotDePasse9!');
      expect(dump).not.toContain('passwordHash');
      expect(dump).not.toContain('$argon2');
    });

    it('un changement de RÔLE est tracé avec l’avant et l’après', async () => {
      const created = await createUser('role');

      await as(adminToken)
        .patch(`/api/users/${created.id}`)
        .send({ roles: [RoleCode.MAGASINIER] })
        .expect(200);

      const update = (await auditFor(created.id)).find((e) => e.action === 'UPDATE');
      expect(update!.oldValue).toMatchObject({ roles: ['VENDEUR'] });
      expect(update!.newValue).toMatchObject({ roles: ['MAGASINIER'] });
    });

    it('cumuler des fonctions passe par les RÔLES : tracé et effectif au login', async () => {
      const created = await createUser('cumul');

      const res = await as(adminToken)
        .patch(`/api/users/${created.id}`)
        .send({ roles: [RoleCode.VENDEUR, RoleCode.MAGASINIER] })
        .expect(200);
      // Les permissions effectives sont l'union des deux rôles.
      expect(res.body.permissions).toEqual(expect.arrayContaining(['sale.create', 'stock.loss']));

      const update = (await auditFor(created.id)).find((e) => e.action === 'UPDATE');
      expect(update!.oldValue).toMatchObject({ roles: ['VENDEUR'] });
      expect((update!.newValue as { roles: string[] }).roles).toEqual(
        expect.arrayContaining(['VENDEUR', 'MAGASINIER']),
      );

      const session = await login(created.email, PASSWORD);
      expect(session.body.user.permissions).toContain('stock.loss');
    });

    it('une désactivation est tracée et coupe les sessions', async () => {
      const target = await sessionFor('off', [RoleCode.VENDEUR]);

      await as(adminToken).patch(`/api/users/${target.id}`).send({ isActive: false }).expect(200);

      const update = (await auditFor(target.id)).find((e) => e.action === 'UPDATE');
      expect(update!.oldValue).toMatchObject({ isActive: true });
      expect(update!.newValue).toMatchObject({ isActive: false });
      expect(
        await prisma.refreshToken.count({ where: { userId: target.id, revokedAt: null } }),
      ).toBe(0);
    });

    it('une réinitialisation : tracée sans secret, ancien mot de passe refusé, sessions coupées', async () => {
      const target = await sessionFor('reset', [RoleCode.VENDEUR]);
      const session = await login(target.email, PASSWORD);

      await as(adminToken)
        .post(`/api/users/${target.id}/reset-password`)
        .send({ temporaryPassword: 'NouveauTemporaire1!' })
        .expect(200);

      const update = (await auditFor(target.id)).find((e) => e.action === 'UPDATE');
      expect(update!.newValue).toMatchObject({ operation: 'PASSWORD_RESET', mustChangePassword: true });
      expect(JSON.stringify(update!.newValue)).not.toContain('NouveauTemporaire1!');

      expect((await login(target.email, PASSWORD)).status).toBe(401);
      const withTemporary = await login(target.email, 'NouveauTemporaire1!');
      expect(withTemporary.status).toBe(200);
      expect(withTemporary.body.user.mustChangePassword).toBe(true);
      const oldRefresh = await request(server)
        .post('/api/auth/refresh')
        .send({ refreshToken: session.body.refreshToken });
      expect(oldRefresh.status).toBe(401);
    });

    it('une révocation de sessions est tracée avec leur nombre', async () => {
      const created = await createUser('revoke');
      // Deux connexions = deux sessions à révoquer.
      await login(created.email, PASSWORD);
      await login(created.email, PASSWORD);

      const response = await as(adminToken)
        .post(`/api/users/${created.id}/revoke-sessions`)
        .expect(200);

      expect(response.body.revoked).toBe(2);
      const update = (await auditFor(created.id)).find(
        (e) => (e.newValue as Record<string, unknown>)?.operation === 'REVOKE_SESSIONS',
      );
      expect(update!.newValue).toMatchObject({ operation: 'REVOKE_SESSIONS', revokedSessions: 2 });
    });
  });

  describe('atomicité (règles 3 et 7)', () => {
    it('un échec d’audit DANS la transaction annule la modification', async () => {
      const target = await sessionFor('atomique', [RoleCode.VENDEUR]);
      const before = (await auditFor(target.id)).length;

      failAuditInNextTransaction(prisma);
      await as(adminToken)
        .patch(`/api/users/${target.id}`)
        .send({ fullName: 'Nom Jamais Écrit', isActive: false })
        .expect(500);

      const user = await prisma.user.findUniqueOrThrow({ where: { id: target.id } });
      expect(user.fullName).not.toBe('Nom Jamais Écrit');
      expect(user.isActive).toBe(true);
      // La révocation faisait partie de la transaction : les sessions survivent.
      expect(
        await prisma.refreshToken.count({ where: { userId: target.id, revokedAt: null } }),
      ).toBeGreaterThan(0);
      expect((await auditFor(target.id)).length).toBe(before);
    });

    it('un échec d’audit DANS la transaction annule la création', async () => {
      const email = uniqueEmail('creation-annulee');

      failAuditInNextTransaction(prisma);
      await as(adminToken)
        .post('/api/users')
        .send({ email, fullName: 'Jamais Créé', temporaryPassword: PASSWORD, roles: [RoleCode.VENDEUR] })
        .expect(500);

      expect(await prisma.user.count({ where: { email } })).toBe(0);
    });
  });

  describe('garde-fous d’administration', () => {
    it('le DERNIER admin actif ne peut être ni désactivé ni rétrogradé', async () => {
      // Appel direct du service : via l'API, l'auteur est lui-même un admin actif,
      // ce cas n'est atteignable que par une course (testée ci-dessous).
      const last = await sessionFor('dernier', [RoleCode.ADMIN]);
      const service = e2e.app.get(UsersService);

      await withOnlyTheseAdminsActive([last.id], async () => {
        for (const change of [{ isActive: false }, { roles: [RoleCode.VENDEUR] }]) {
          await expect(
            service.update(last.id, change, { userId: adminId }),
          ).rejects.toMatchObject({ response: { code: 'LAST_ACTIVE_ADMIN' } });
        }
      });
      expect((await prisma.user.findUniqueOrThrow({ where: { id: last.id } })).isActive).toBe(true);
    });

    it('deux admins qui se retirent MUTUELLEMENT en même temps : il en reste un', async () => {
      for (const change of [{ isActive: false }, { roles: [RoleCode.VENDEUR] }]) {
        const a = await sessionFor('duel-a', [RoleCode.ADMIN]);
        const b = await sessionFor('duel-b', [RoleCode.ADMIN]);

        await withOnlyTheseAdminsActive([a.id, b.id], async () => {
          const results = await Promise.all([
            as(a.token).patch(`/api/users/${b.id}`).send(change),
            as(b.token).patch(`/api/users/${a.id}`).send(change),
          ]);

          const statuses = results.map((r) => r.status);
          expect(statuses.filter((s) => s === 200)).toHaveLength(1);
          // Le perdant est arrêté soit par le verrou (409), soit par le guard qui
          // relit son accès en base (403) s'il arrive après le commit du gagnant —
          // ou 401 : une désactivation révoque ses sessions, et le guard lit compte et
          // session en parallèle, la session pouvant être lue juste après ce commit.
          expect(statuses.find((s) => s !== 200)).toBeOneOf([401, 403, 409]);
          expect(
            await prisma.user.count({
              where: { id: { in: [a.id, b.id] }, isActive: true, roles: { some: { code: RoleCode.ADMIN } } },
            }),
          ).toBe(1);
        });
      }
    });

    it('un admin ne modifie ni ses propres rôles, ni sa propre activation', async () => {
      const self = await sessionFor('soi', [RoleCode.ADMIN]);

      for (const change of [
        { roles: [RoleCode.ADMIN, RoleCode.MAGASINIER] },
        { isActive: false },
      ]) {
        const res = await as(self.token).patch(`/api/users/${self.id}`).send(change);
        expect(res.status).toBe(403);
        expect(res.body.code).toBe('SELF_MODIFICATION_FORBIDDEN');
      }
      // Son nom, lui, reste modifiable.
      await as(self.token).patch(`/api/users/${self.id}`).send({ fullName: 'Nouveau Nom' }).expect(200);
    });

    it('un admin RÉTROGRADÉ perd la main tout de suite, malgré son token encore valide', async () => {
      const demoted = await sessionFor('retrograde', [RoleCode.ADMIN]);
      await as(adminToken)
        .patch(`/api/users/${demoted.id}`)
        .send({ roles: [RoleCode.VENDEUR] })
        .expect(200);

      // Son access token dit encore ADMIN : l'accès est relu en base.
      const res = await as(demoted.token).patch(`/api/users/${demoted.id}`).send({ fullName: 'x' });
      expect(res.status).toBe(403);
      expect(res.body.code).toBe('FORBIDDEN_ROLE');
      expect((await as(demoted.token).get('/api/users')).status).toBe(403);
    });

    it('un admin DÉSACTIVÉ ne peut pas se réactiver avec son token encore valide', async () => {
      const disabled = await sessionFor('desactive', [RoleCode.ADMIN]);
      await as(adminToken).patch(`/api/users/${disabled.id}`).send({ isActive: false }).expect(200);

      const other = await createUser('victime', RoleCode.MAGASINIER);
      const res = await as(disabled.token).patch(`/api/users/${other.id}`).send({ isActive: false });

      expect(res.status).toBe(403);
      expect(res.body.code).toBe('ACCOUNT_DISABLED');
    });
  });

  describe('aucune permission « à la carte » (décision 2026-09-13)', () => {
    it('le champ n’existe plus : refusé à la création comme à la modification', async () => {
      // Sans ce refus, un admin pourrait croire avoir accordé `sale.discount` à un
      // vendeur — règle ferme : la remise reste réservée à l'ADMIN.
      const created = await as(adminToken)
        .post('/api/users')
        .send({
          email: uniqueEmail('remise'),
          fullName: 'Vendeur Remise',
          temporaryPassword: PASSWORD,
          roles: [RoleCode.VENDEUR],
          extraPermissions: ['sale.discount'],
        });
      expect(created.status).toBe(400);
      expect(created.body.code).toBe('VALIDATION_FAILED');

      const vendeur = await createUser('prix');
      const update = await as(adminToken)
        .patch(`/api/users/${vendeur.id}`)
        .send({ extraPermissions: ['price.manage'] });
      expect(update.status).toBe(400);
      expect(update.body.code).toBe('VALIDATION_FAILED');
    });

    it('une permission directe résiduelle en base n’accorde plus RIEN, même sur une vraie route', async () => {
      // Lignes écrites avant la décision : elles restent en base (pas de migration
      // destructive) mais ne doivent plus ouvrir d'accès.
      const vendeur = await sessionFor('residu', [RoleCode.VENDEUR]);
      await prisma.user.update({
        where: { id: vendeur.id },
        data: { permissions: { connect: [{ code: 'price.manage' }, { code: 'supplier.read' }] } },
      });

      const res = await as(adminToken).get(`/api/users/${vendeur.id}`).expect(200);
      expect(res.body.permissions).not.toContain('price.manage');
      expect(res.body.permissions).not.toContain('supplier.read');
      expect(res.body.extraPermissions).toBeUndefined();

      // Preuve sur une route réellement protégée, avec un token émis APRÈS l'ajout :
      // la matrice validée ferme les fournisseurs au vendeur.
      const fresh = await login(vendeur.email, PASSWORD);
      const suppliers = await as(fresh.body.accessToken).get('/api/suppliers');
      expect(suppliers.status).toBe(403);
      expect(suppliers.body.code).toBe('FORBIDDEN_PERMISSION');
    });
  });

  describe('contrôle d’accès', () => {
    it('VENDEUR et MAGASINIER ne créent ni ne modifient de compte', async () => {
      const vendeur = await sessionFor('pas-admin-v', [RoleCode.VENDEUR]);
      const magasinier = await sessionFor('pas-admin-m', [RoleCode.MAGASINIER]);

      for (const token of [vendeur.token, magasinier.token]) {
        const create = await as(token).post('/api/users').send({
          email: uniqueEmail('intrus'),
          fullName: 'Intrus',
          temporaryPassword: PASSWORD,
          roles: [RoleCode.ADMIN],
        });
        expect(create.status).toBe(403);
        const update = await as(token).patch(`/api/users/${vendeur.id}`).send({ roles: [RoleCode.ADMIN] });
        expect(update.status).toBe(403);
      }
    });
  });

  describe('validation des entrées', () => {
    it('un email déjà pris (quelle que soit la casse) est refusé (409)', async () => {
      const res = await as(adminToken).post('/api/users').send({
        email: adminEmail.toUpperCase(),
        fullName: 'Doublon',
        temporaryPassword: PASSWORD,
        roles: [RoleCode.VENDEUR],
      });

      expect(res.status).toBe(409);
      expect(res.body.code).toBe('CONFLICT');
    });

    it('un compte sans aucun identifiant de connexion est refusé (400)', async () => {
      const res = await as(adminToken).post('/api/users').send({
        fullName: 'Sans Identifiant',
        temporaryPassword: PASSWORD,
        roles: [RoleCode.VENDEUR],
      });

      expect(res.status).toBe(400);
      expect(res.body.code).toBe('VALIDATION_FAILED');
    });

    it('refuse null, une liste de rôles vide et un téléphone invalide (400, jamais 500)', async () => {
      const created = await createUser('validation');

      for (const body of [
        { fullName: null },
        { email: null },
        { roles: [] },
        { phone: 'pas-un-numero' },
        { isActive: null },
      ]) {
        const res = await as(adminToken).patch(`/api/users/${created.id}`).send(body);
        expect({ body, status: res.status }).toEqual({ body, status: 400 });
        expect(res.body.code).toBe('VALIDATION_FAILED');
      }
    });
  });

  describe('liste et catalogue', () => {
    it('trie sur un champ autorisé, refuse un champ hors liste blanche', async () => {
      const marker = `tri${suffix}`;
      for (const name of ['Zoé', 'Adam']) {
        const user = await createTestUser(prisma, {
          email: uniqueEmail(`${marker}-${name.toLowerCase()}`),
          password: PASSWORD,
          roles: [RoleCode.VENDEUR],
          fullName: `${name} ${marker}`,
        });
        createdIds.push(user.id);
      }

      const asc = await as(adminToken).get(`/api/users?q=${marker}&sort=fullName:asc`).expect(200);
      expect(asc.body.data.map((u: { fullName: string }) => u.fullName.split(' ')[0])).toEqual(['Adam', 'Zoé']);

      const refused = await as(adminToken).get(`/api/users?sort=passwordHash:asc`);
      expect(refused.status).toBe(400);
      expect(refused.body.code).toBe('VALIDATION_FAILED');
    });

    it('l’audit reste réservé à l’ADMIN', async () => {
      const vendeur = await sessionFor('audit-vendeur', [RoleCode.VENDEUR]);

      const response = await as(vendeur.token).get('/api/audit-logs');

      expect(response.status).toBe(403);
      expect(response.body.code).toBe('FORBIDDEN_ROLE');
    });
  });
});

expect.extend({
  toBeOneOf(received: unknown, expected: unknown[]) {
    const pass = expected.includes(received);
    return {
      pass,
      message: () => `attendu l'une des valeurs ${JSON.stringify(expected)}, reçu ${JSON.stringify(received)}`,
    };
  },
});

declare global {
  // eslint-disable-next-line @typescript-eslint/no-namespace
  namespace jest {
    interface Matchers<R> {
      toBeOneOf(expected: unknown[]): R;
    }
  }
}
