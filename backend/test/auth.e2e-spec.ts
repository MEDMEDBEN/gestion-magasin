import { INestApplication, ValidationPipe } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import * as request from 'supertest';
import { AppModule } from '../src/app.module';
import { RoleCode } from '../src/common/auth.decorators';
import { HttpExceptionFilter } from '../src/common/http-exception.filter';
import { PrismaService } from '../src/prisma/prisma.service';

/// Tests d'intégration de l'authentification, sur la vraie base de dev.
/// Les comptes créés portent un suffixe unique et sont supprimés à la fin.
describe('Auth (e2e)', () => {
  let app: INestApplication;
  let prisma: PrismaService;
  let server: ReturnType<INestApplication['getHttpServer']>;

  const suffix = Date.now();
  const adminEmail = `e2e-admin-${suffix}@test.local`;
  const vendeurEmail = `e2e-vendeur-${suffix}@test.local`;
  const TEMP_PASSWORD = 'MotDePasseTemp1!';
  const NEW_PASSWORD = 'NouveauMotDePasse1!';

  /// Connecte un compte et renvoie ses tokens.
  const login = (identifier: string, password: string) =>
    request(server).post('/api/auth/login').send({ identifier, password });

  beforeAll(async () => {
    const moduleRef = await Test.createTestingModule({
      imports: [AppModule],
    }).compile();

    app = moduleRef.createNestApplication();
    app.setGlobalPrefix('api');
    app.useGlobalFilters(new HttpExceptionFilter());
    app.useGlobalPipes(
      new ValidationPipe({ whitelist: true, forbidNonWhitelisted: true, transform: true }),
    );
    await app.init();

    prisma = app.get(PrismaService);
    server = app.getHttpServer();

    // Deux comptes de test : un admin et un vendeur, mot de passe déjà changé.
    const { AuthService } = await import('../src/auth/auth.service');
    const passwordHash = await AuthService.hashPassword(TEMP_PASSWORD);
    for (const [email, role] of [
      [adminEmail, RoleCode.ADMIN],
      [vendeurEmail, RoleCode.VENDEUR],
    ] as const) {
      await prisma.user.create({
        data: {
          email,
          fullName: `E2E ${role}`,
          passwordHash,
          mustChangePassword: false,
          roles: { connect: { code: role } },
        },
      });
    }
  });

  afterAll(async () => {
    await prisma.user.deleteMany({
      where: { email: { in: [adminEmail, vendeurEmail] } },
    });
    await app.close();
  });

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

    const refreshed = await request(server)
      .post('/api/auth/refresh')
      .send({ refreshToken: oldRefresh });
    expect(refreshed.status).toBe(200);
    expect(refreshed.body.refreshToken).not.toBe(oldRefresh);

    // Rejouer l'ancien : refusé, et toutes les sessions sont coupées (vol présumé).
    const replay = await request(server)
      .post('/api/auth/refresh')
      .send({ refreshToken: oldRefresh });
    expect(replay.status).toBe(401);
    expect(replay.body.code).toBe('REFRESH_TOKEN_REVOKED');

    // Le token neuf a été révoqué par la détection de rejeu.
    const afterCascade = await request(server)
      .post('/api/auth/refresh')
      .send({ refreshToken: refreshed.body.refreshToken });
    expect(afterCascade.status).toBe(401);
  });

  it('un refresh révoqué par logout est rejeté', async () => {
    const session = await login(adminEmail, TEMP_PASSWORD);

    const logout = await request(server)
      .post('/api/auth/logout')
      .set('Authorization', `Bearer ${session.body.accessToken}`)
      .send({ refreshToken: session.body.refreshToken });
    expect(logout.status).toBe(200);
    expect(logout.body.revoked).toBe(1);

    const res = await request(server)
      .post('/api/auth/refresh')
      .send({ refreshToken: session.body.refreshToken });

    expect(res.status).toBe(401);
    expect(res.body.code).toBe('REFRESH_TOKEN_REVOKED');
  });

  it('un refresh inconnu est rejeté', async () => {
    const res = await request(server)
      .post('/api/auth/refresh')
      .send({ refreshToken: 'token-qui-n-existe-pas' });

    expect(res.status).toBe(401);
    expect(res.body.code).toBe('REFRESH_TOKEN_INVALID');
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

    const session = await login(email, TEMP_PASSWORD);
    expect(session.body.user.mustChangePassword).toBe(true);

    // Toute route normale est fermée...
    const blocked = await request(server)
      .get('/api/auth/me')
      .set('Authorization', `Bearer ${session.body.accessToken}`);
    expect(blocked.status).toBe(403);
    expect(blocked.body.code).toBe('PASSWORD_CHANGE_REQUIRED');

    // ... sauf le changement de mot de passe.
    const changed = await request(server)
      .post('/api/auth/change-password')
      .set('Authorization', `Bearer ${session.body.accessToken}`)
      .send({ currentPassword: TEMP_PASSWORD, newPassword: NEW_PASSWORD });
    expect(changed.status).toBe(200);
    expect(changed.body.user.mustChangePassword).toBe(false);

    // Le verrou est levé avec les tokens neufs.
    const unlocked = await request(server)
      .get('/api/auth/me')
      .set('Authorization', `Bearer ${changed.body.accessToken}`);
    expect(unlocked.status).toBe(200);

    // L'ancien mot de passe ne fonctionne plus.
    const oldPassword = await login(email, TEMP_PASSWORD);
    expect(oldPassword.status).toBe(401);

    await prisma.user.deleteMany({ where: { email } });
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

    await request(server)
      .patch(`/api/users/${created.body.id}`)
      .set('Authorization', `Bearer ${admin.body.accessToken}`)
      .send({ isActive: false })
      .expect(200);

    const res = await login(email, TEMP_PASSWORD);
    expect(res.status).toBe(403);
    expect(res.body.code).toBe('ACCOUNT_DISABLED');

    await prisma.user.deleteMany({ where: { email } });
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
      .get('/api/products')
      .set('Authorization', `Bearer ${session.body.accessToken}`);

    expect(res.status).toBe(501);
    expect(res.body.code).toBe('NOT_IMPLEMENTED');
  });

  it('refuse de réutiliser le mot de passe courant au changement', async () => {
    const email = `e2e-reuse-${suffix}@test.local`;
    const admin = await login(adminEmail, TEMP_PASSWORD);

    await request(server)
      .post('/api/users')
      .set('Authorization', `Bearer ${admin.body.accessToken}`)
      .send({
        email,
        fullName: 'Réutilisation',
        temporaryPassword: TEMP_PASSWORD,
        roles: [RoleCode.VENDEUR],
      })
      .expect(201);

    const session = await login(email, TEMP_PASSWORD);
    const res = await request(server)
      .post('/api/auth/change-password')
      .set('Authorization', `Bearer ${session.body.accessToken}`)
      .send({ currentPassword: TEMP_PASSWORD, newPassword: TEMP_PASSWORD });

    expect(res.status).toBe(400);
    expect(res.body.code).toBe('VALIDATION_FAILED');

    await prisma.user.deleteMany({ where: { email } });
  });

  it('refuse un code de permission inconnu (400, pas 500)', async () => {
    const admin = await login(adminEmail, TEMP_PASSWORD);

    const res = await request(server)
      .post('/api/users')
      .set('Authorization', `Bearer ${admin.body.accessToken}`)
      .send({
        email: `e2e-badperm-${suffix}@test.local`,
        fullName: 'Permission Inconnue',
        temporaryPassword: TEMP_PASSWORD,
        roles: [RoleCode.VENDEUR],
        extraPermissions: ['permission.qui.nexiste.pas'],
      });

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
