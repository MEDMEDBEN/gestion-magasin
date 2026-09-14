import * as request from 'supertest';
import { RoleCode } from '../src/common/auth.decorators';
import { PrismaService } from '../src/prisma/prisma.service';
import {
  createE2eApp,
  createTestUser,
  E2eApp,
  failAuditInNextTransaction,
} from './helpers/e2e-app';

/// Tests d'intégration de l'authentification, sur la vraie base de dev.
/// Les comptes créés portent un suffixe unique et sont supprimés à la fin.
describe('Auth (e2e)', () => {
  let e2e: E2eApp;
  let prisma: PrismaService;
  let server: E2eApp['server'];

  const suffix = Date.now();
  const adminEmail = `e2e-admin-${suffix}@test.local`;
  const vendeurEmail = `e2e-vendeur-${suffix}@test.local`;
  const TEMP_PASSWORD = 'MotDePasseTemp1!';
  const NEW_PASSWORD = 'NouveauMotDePasse1!';
  const createdIds: string[] = [];

  /// Connecte un compte et renvoie ses tokens.
  const login = (identifier: string, password: string, deviceId?: string) =>
    request(server)
      .post('/api/auth/login')
      .send({ identifier, password, ...(deviceId ? { deviceId } : {}) });

  const refresh = (refreshToken: string) =>
    request(server).post('/api/auth/refresh').send({ refreshToken });

  /// Compte jetable, suivi pour le nettoyage.
  const newUser = async (
    label: string,
    role: RoleCode = RoleCode.VENDEUR,
    extra: { mustChangePassword?: boolean; isActive?: boolean } = {},
  ) => {
    const email = `e2e-${label}-${suffix}@test.local`;
    const user = await createTestUser(prisma, {
      email,
      password: TEMP_PASSWORD,
      roles: [role],
      ...extra,
    });
    createdIds.push(user.id);
    return { ...user, email };
  };

  const activeSessions = (userId: string) =>
    prisma.refreshToken.count({ where: { userId, revokedAt: null } });

  const auditOps = async (userId: string) =>
    (
      await prisma.auditLog.findMany({
        where: { entityType: 'User', entityId: userId },
        orderBy: { createdAt: 'asc' },
      })
    ).map((entry) => (entry.newValue as Record<string, unknown> | null)?.operation);

  beforeAll(async () => {
    e2e = await createE2eApp();
    prisma = e2e.prisma;
    server = e2e.server;

    // Deux comptes de test : un admin et un vendeur, mot de passe déjà changé.
    for (const [email, role] of [
      [adminEmail, RoleCode.ADMIN],
      [vendeurEmail, RoleCode.VENDEUR],
    ] as const) {
      const user = await createTestUser(prisma, {
        email,
        password: TEMP_PASSWORD,
        roles: [role],
      });
      createdIds.push(user.id);
    }
  });

  afterAll(async () => {
    await prisma.auditLog.deleteMany({
      where: { OR: [{ entityId: { in: createdIds } }, { userId: { in: createdIds } }] },
    });
    await prisma.user.deleteMany({ where: { id: { in: createdIds } } });
    await e2e.app.close();
  });

  afterEach(() => jest.restoreAllMocks());

  it('refuse un mot de passe incorrect', async () => {
    const res = await login(adminEmail, 'MauvaisMotDePasse');

    expect(res.status).toBe(401);
    expect(res.body.code).toBe('INVALID_CREDENTIALS');
  });

  it('donne la même erreur pour un compte inexistant (pas d’énumération)', async () => {
    const res = await login('inconnu@test.local', 'peu-importe');

    expect(res.status).toBe(401);
    expect(res.body.code).toBe('INVALID_CREDENTIALS');
  });

  it('login puis accès à une route protégée', async () => {
    const res = await login(adminEmail, TEMP_PASSWORD);
    expect(res.status).toBe(200);
    expect(res.body.accessToken).toBeDefined();
    expect(res.body.user.roles).toEqual(['ADMIN']);

    const me = await request(server)
      .get('/api/auth/me')
      .set('Authorization', `Bearer ${res.body.accessToken}`);

    expect(me.status).toBe(200);
    expect(me.body.email).toBe(adminEmail);
    expect(me.body.permissions).toContain('user.manage');
  });

  it('refuse une route protégée sans token', async () => {
    const res = await request(server).get('/api/auth/me');

    expect(res.status).toBe(401);
  });

  it('le refresh fait la ROTATION : l’ancien token devient inutilisable', async () => {
    const first = await login(adminEmail, TEMP_PASSWORD);
    const oldRefresh = first.body.refreshToken;

    const refreshed = await refresh(oldRefresh);
    expect(refreshed.status).toBe(200);
    expect(refreshed.body.refreshToken).not.toBe(oldRefresh);

    // Rejouer l'ancien : refusé, et toutes les sessions sont coupées (vol présumé).
    const replay = await refresh(oldRefresh);
    expect(replay.status).toBe(401);
    expect(replay.body.code).toBe('REFRESH_TOKEN_REVOKED');

    // Le token neuf a été révoqué par la détection de rejeu.
    const afterCascade = await refresh(refreshed.body.refreshToken);
    expect(afterCascade.status).toBe(401);
  });

  it('un rejeu de refresh token est TRACÉ dans l’audit (vol présumé)', async () => {
    const user = await newUser('rejeu');
    const session = await login(user.email, TEMP_PASSWORD);
    await refresh(session.body.refreshToken).expect(200);

    await refresh(session.body.refreshToken).expect(401);

    const entry = await prisma.auditLog.findFirst({
      where: { entityType: 'User', entityId: user.id },
      orderBy: { createdAt: 'desc' },
    });
    expect(entry?.newValue).toMatchObject({ operation: 'REFRESH_TOKEN_REUSE_DETECTED' });
    // Pas d'auteur authentifié : c'est le serveur qui réagit.
    expect(entry?.userId).toBeNull();
  });

  it('deux refresh CONCURRENTS du même token : un seul réussit', async () => {
    const user = await newUser('concurrent');
    const session = await login(user.email, TEMP_PASSWORD);

    const results = await Promise.all([
      refresh(session.body.refreshToken),
      refresh(session.body.refreshToken),
    ]);

    expect(results.map((r) => r.status).sort()).toEqual([200, 401]);
  });

  it('un refresh EXPIRÉ est refusé avec son code', async () => {
    const user = await newUser('expire');
    const session = await login(user.email, TEMP_PASSWORD);
    await prisma.refreshToken.updateMany({
      where: { userId: user.id },
      data: { expiresAt: new Date(Date.now() - 1000) },
    });

    const res = await refresh(session.body.refreshToken);

    expect(res.status).toBe(401);
    expect(res.body.code).toBe('REFRESH_TOKEN_EXPIRED');
  });

  it('le refresh d’un compte DÉSACTIVÉ est refusé et ferme ses sessions', async () => {
    const user = await newUser('refresh-off');
    const session = await login(user.email, TEMP_PASSWORD);
    await prisma.user.update({ where: { id: user.id }, data: { isActive: false } });

    const res = await refresh(session.body.refreshToken);

    expect(res.status).toBe(403);
    expect(res.body.code).toBe('ACCOUNT_DISABLED');
    expect(await activeSessions(user.id)).toBe(0);
  });

  it('logout SANS access token : le refresh token suffit comme preuve', async () => {
    const session = await login(adminEmail, TEMP_PASSWORD);

    // Aucun en-tête Authorization : un access token expiré ne doit jamais
    // empêcher de fermer la session (sinon le logout révoquait un token périmé).
    const logout = await request(server)
      .post('/api/auth/logout')
      .send({ refreshToken: session.body.refreshToken });
    expect(logout.status).toBe(200);
    expect(logout.body.revoked).toBe(1);

    const res = await refresh(session.body.refreshToken);
    expect(res.status).toBe(401);
    expect(res.body.code).toBe('REFRESH_TOKEN_REVOKED');
  });

  it('logout d’un token inconnu ne révèle rien', async () => {
    const res = await request(server)
      .post('/api/auth/logout')
      .send({ refreshToken: 'a'.repeat(64) });

    expect(res.status).toBe(200);
    expect(res.body.revoked).toBe(0);
  });

  it('logout allDevices ferme TOUTES les sessions et le trace', async () => {
    const user = await newUser('all-devices');
    const phone = await login(user.email, TEMP_PASSWORD, 'telephone');
    const desktop = await login(user.email, TEMP_PASSWORD, 'poste');

    const res = await request(server)
      .post('/api/auth/logout')
      .send({ refreshToken: desktop.body.refreshToken, allDevices: true });

    expect(res.status).toBe(200);
    expect(res.body.revoked).toBe(2);
    expect((await refresh(phone.body.refreshToken)).status).toBe(401);
    expect(await auditOps(user.id)).toContain('LOGOUT_ALL_DEVICES');
  });

  it('une reconnexion depuis le MÊME appareil remplace sa session précédente', async () => {
    const user = await newUser('meme-appareil');

    await login(user.email, TEMP_PASSWORD, 'mobile-42').expect(200);
    await login(user.email, TEMP_PASSWORD, 'mobile-42').expect(200);
    await login(user.email, TEMP_PASSWORD, 'autre-appareil').expect(200);

    const active = await prisma.refreshToken.findMany({
      where: { userId: user.id, revokedAt: null },
      select: { deviceId: true },
    });
    expect(active.map((t) => t.deviceId).sort()).toEqual(['autre-appareil', 'mobile-42']);
  });

  it('un VENDEUR est bloqué sur une route ADMIN', async () => {
    const session = await login(vendeurEmail, TEMP_PASSWORD);

    const res = await request(server)
      .get('/api/users')
      .set('Authorization', `Bearer ${session.body.accessToken}`);

    expect(res.status).toBe(403);
    expect(res.body.code).toBe('FORBIDDEN_ROLE');
  });

  it('un ADMIN accède à la route ADMIN', async () => {
    const session = await login(adminEmail, TEMP_PASSWORD);

    const res = await request(server)
      .get('/api/users')
      .set('Authorization', `Bearer ${session.body.accessToken}`);

    expect(res.status).toBe(200);
    expect(res.body.meta).toMatchObject({ page: 1, limit: 50 });
  });

  it('refuse une limite de pagination au-delà de 200', async () => {
    const session = await login(adminEmail, TEMP_PASSWORD);

    const res = await request(server)
      .get('/api/users?limit=201')
      .set('Authorization', `Bearer ${session.body.accessToken}`);

    expect(res.status).toBe(400);
    expect(res.body.code).toBe('VALIDATION_FAILED');
  });

  it('mustChangePassword verrouille tout sauf le changement de mot de passe', async () => {
    const email = `e2e-neuf-${suffix}@test.local`;
    const admin = await login(adminEmail, TEMP_PASSWORD);

    // L'admin crée le compte : mot de passe temporaire imposé.
    const created = await request(server)
      .post('/api/users')
      .set('Authorization', `Bearer ${admin.body.accessToken}`)
      .send({
        email,
        fullName: 'Nouveau Vendeur',
        temporaryPassword: TEMP_PASSWORD,
        roles: [RoleCode.VENDEUR],
      });
    expect(created.status).toBe(201);
    expect(created.body.mustChangePassword).toBe(true);
    createdIds.push(created.body.id);

    const session = await login(email, TEMP_PASSWORD);
    expect(session.body.user.mustChangePassword).toBe(true);

    // Toute route MÉTIER est fermée...
    const blocked = await request(server)
      .get('/api/products')
      .set('Authorization', `Bearer ${session.body.accessToken}`);
    expect(blocked.status).toBe(403);
    expect(blocked.body.code).toBe('PASSWORD_CHANGE_REQUIRED');

    // ... mais /auth/me reste lisible : l'app doit savoir qui elle affiche
    // sur l'écran de changement de mot de passe.
    const whoAmI = await request(server)
      .get('/api/auth/me')
      .set('Authorization', `Bearer ${session.body.accessToken}`);
    expect(whoAmI.status).toBe(200);
    expect(whoAmI.body.mustChangePassword).toBe(true);

    // ... sauf le changement de mot de passe.
    const changed = await request(server)
      .post('/api/auth/change-password')
      .set('Authorization', `Bearer ${session.body.accessToken}`)
      .send({ currentPassword: TEMP_PASSWORD, newPassword: NEW_PASSWORD });
    expect(changed.status).toBe(200);
    expect(changed.body.user.mustChangePassword).toBe(false);

    // Le verrou métier est levé avec les tokens neufs.
    const unlocked = await request(server)
      .get('/api/products')
      .set('Authorization', `Bearer ${changed.body.accessToken}`);
    expect(unlocked.status).not.toBe(403);

    // L'ancien mot de passe ne fonctionne plus.
    const oldPassword = await login(email, TEMP_PASSWORD);
    expect(oldPassword.status).toBe(401);
  });

  it('change-password est REFUSÉ à un compte désactivé, sans émettre de token (C1)', async () => {
    const user = await newUser('cp-off');
    const session = await login(user.email, TEMP_PASSWORD);
    // Désactivé APRÈS la connexion : son access token vit encore ≤ 15 min.
    await prisma.user.update({ where: { id: user.id }, data: { isActive: false } });
    await prisma.refreshToken.updateMany({
      where: { userId: user.id },
      data: { revokedAt: new Date() },
    });

    const res = await request(server)
      .post('/api/auth/change-password')
      .set('Authorization', `Bearer ${session.body.accessToken}`)
      .send({ currentPassword: TEMP_PASSWORD, newPassword: NEW_PASSWORD });

    expect(res.status).toBe(403);
    expect(res.body.code).toBe('ACCOUNT_DISABLED');
    expect(res.body.accessToken).toBeUndefined();
    expect(await activeSessions(user.id)).toBe(0);
  });

  it('/auth/me refuse un compte désactivé', async () => {
    const user = await newUser('me-off');
    const session = await login(user.email, TEMP_PASSWORD);
    await prisma.user.update({ where: { id: user.id }, data: { isActive: false } });

    const res = await request(server)
      .get('/api/auth/me')
      .set('Authorization', `Bearer ${session.body.accessToken}`);

    expect(res.status).toBe(403);
    expect(res.body.code).toBe('ACCOUNT_DISABLED');
  });

  it('change-password est tracé (sans secret) et garde l’appareil de la session', async () => {
    const user = await newUser('cp-audit');
    const session = await login(user.email, TEMP_PASSWORD, 'tablette-1');

    await request(server)
      .post('/api/auth/change-password')
      .set('Authorization', `Bearer ${session.body.accessToken}`)
      .send({
        currentPassword: TEMP_PASSWORD,
        newPassword: NEW_PASSWORD,
        deviceId: 'tablette-1',
      })
      .expect(200);

    const entries = await prisma.auditLog.findMany({
      where: { entityType: 'User', entityId: user.id },
    });
    expect(entries.map((e) => (e.newValue as Record<string, unknown>).operation)).toContain(
      'PASSWORD_CHANGE',
    );
    const dump = JSON.stringify(entries);
    expect(dump).not.toContain(TEMP_PASSWORD);
    expect(dump).not.toContain(NEW_PASSWORD);

    const active = await prisma.refreshToken.findMany({
      where: { userId: user.id, revokedAt: null },
    });
    expect(active).toHaveLength(1);
    expect(active[0].deviceId).toBe('tablette-1');
  });

  it('change-password est ATOMIQUE : un échec d’audit annule tout', async () => {
    const user = await newUser('cp-atomique');
    const session = await login(user.email, TEMP_PASSWORD);

    failAuditInNextTransaction(prisma);
    const res = await request(server)
      .post('/api/auth/change-password')
      .set('Authorization', `Bearer ${session.body.accessToken}`)
      .send({ currentPassword: TEMP_PASSWORD, newPassword: NEW_PASSWORD });
    expect(res.status).toBe(500);

    // Rien n'a été appliqué : ancien mot de passe valable, session d'origine vivante.
    expect((await login(user.email, NEW_PASSWORD)).status).toBe(401);
    expect((await refresh(session.body.refreshToken)).status).toBe(200);
  });

  it('un mauvais mot de passe ACTUEL a son propre code (pas une erreur de login)', async () => {
    const user = await newUser('cp-faux');
    const session = await login(user.email, TEMP_PASSWORD);

    const res = await request(server)
      .post('/api/auth/change-password')
      .set('Authorization', `Bearer ${session.body.accessToken}`)
      .send({ currentPassword: 'PasLeBonMotDePasse', newPassword: NEW_PASSWORD });

    expect(res.status).toBe(403);
    expect(res.body.code).toBe('CURRENT_PASSWORD_INVALID');
  });

  it('un compte désactivé ne peut plus se connecter', async () => {
    const email = `e2e-off-${suffix}@test.local`;
    const admin = await login(adminEmail, TEMP_PASSWORD);

    const created = await request(server)
      .post('/api/users')
      .set('Authorization', `Bearer ${admin.body.accessToken}`)
      .send({
        email,
        fullName: 'Compte Désactivé',
        temporaryPassword: TEMP_PASSWORD,
        roles: [RoleCode.MAGASINIER],
      });
    createdIds.push(created.body.id);

    await request(server)
      .patch(`/api/users/${created.body.id}`)
      .set('Authorization', `Bearer ${admin.body.accessToken}`)
      .send({ isActive: false })
      .expect(200);

    const res = await login(email, TEMP_PASSWORD);
    expect(res.status).toBe(403);
    expect(res.body.code).toBe('ACCOUNT_DISABLED');
  });

  it('l’email se saisit sans souci de casse ni d’espaces', async () => {
    const admin = await login(adminEmail, TEMP_PASSWORD);

    const created = await request(server)
      .post('/api/users')
      .set('Authorization', `Bearer ${admin.body.accessToken}`)
      .send({
        email: `  Karim.MixTe-${suffix}@Test.LOCAL `,
        fullName: 'Karim',
        temporaryPassword: TEMP_PASSWORD,
        roles: [RoleCode.VENDEUR],
      })
      .expect(201);
    createdIds.push(created.body.id);

    expect(created.body.email).toBe(`karim.mixte-${suffix}@test.local`);
    expect((await login(`KARIM.MIXTE-${suffix}@test.local`, TEMP_PASSWORD)).status).toBe(200);
  });

  it('le téléphone se saisit avec ou sans ponctuation', async () => {
    const admin = await login(adminEmail, TEMP_PASSWORD);
    const digits = String(suffix).slice(-8);

    const created = await request(server)
      .post('/api/users')
      .set('Authorization', `Bearer ${admin.body.accessToken}`)
      .send({
        phone: `+213 ${digits.slice(0, 2)}-${digits.slice(2, 5)}.${digits.slice(5)}`,
        fullName: 'Par Téléphone',
        temporaryPassword: TEMP_PASSWORD,
        roles: [RoleCode.MAGASINIER],
      })
      .expect(201);
    createdIds.push(created.body.id);

    expect(created.body.phone).toBe(`+213${digits}`);
    expect((await login(`+213 ${digits}`, TEMP_PASSWORD)).status).toBe(200);
  });

  it('borne la taille des champs d’authentification (anti-DoS argon2)', async () => {
    const tooLongPassword = await login(adminEmail, 'x'.repeat(129));
    const tooLongIdentifier = await login(`${'a'.repeat(300)}@test.local`, TEMP_PASSWORD);

    expect(tooLongPassword.status).toBe(400);
    expect(tooLongPassword.body.code).toBe('VALIDATION_FAILED');
    expect(tooLongIdentifier.status).toBe(400);
  });

  it('rejette un payload avec un champ inconnu (whitelist stricte)', async () => {
    const res = await request(server)
      .post('/api/auth/login')
      .send({ identifier: adminEmail, password: TEMP_PASSWORD, champInconnu: 'x' });

    expect(res.status).toBe(400);
    expect(res.body.code).toBe('VALIDATION_FAILED');
  });

  it('un endpoint au contrat figé répond 501 NOT_IMPLEMENTED, pas 404', async () => {
    const session = await login(adminEmail, TEMP_PASSWORD);

    const res = await request(server)
      .get('/api/sales')
      .set('Authorization', `Bearer ${session.body.accessToken}`);

    expect(res.status).toBe(501);
    expect(res.body.code).toBe('NOT_IMPLEMENTED');
  });

  it('refuse de réutiliser le mot de passe courant au changement', async () => {
    const user = await newUser('reuse', RoleCode.VENDEUR, { mustChangePassword: true });
    const session = await login(user.email, TEMP_PASSWORD);

    const res = await request(server)
      .post('/api/auth/change-password')
      .set('Authorization', `Bearer ${session.body.accessToken}`)
      .send({ currentPassword: TEMP_PASSWORD, newPassword: TEMP_PASSWORD });

    expect(res.status).toBe(400);
    expect(res.body.code).toBe('VALIDATION_FAILED');
  });

  it('un VENDEUR n’a aucun accès aux fournisseurs (matrice validée)', async () => {
    const session = await login(vendeurEmail, TEMP_PASSWORD);

    const res = await request(server)
      .get('/api/suppliers')
      .set('Authorization', `Bearer ${session.body.accessToken}`);

    expect(res.status).toBe(403);
    expect(res.body.code).toBe('FORBIDDEN_PERMISSION');
  });

  it('la sonde /api/health est publique', async () => {
    const res = await request(server).get('/api/health');

    expect(res.status).toBe(200);
    expect(res.body.status).toBe('ok');
  });
});
