import { INestApplication, ValidationPipe } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import * as request from 'supertest';
import { AppModule } from '../src/app.module';
import { RoleCode } from '../src/common/auth.decorators';
import { HttpExceptionFilter } from '../src/common/http-exception.filter';
import { PrismaService } from '../src/prisma/prisma.service';

/// Spec §24 : toute action sensible de gestion de comptes doit laisser une trace
/// « qui / quoi / quand », écrite DANS la transaction de la mutation (règles 3 et 7).
describe('Audit de la gestion des comptes (e2e)', () => {
  let app: INestApplication;
  let prisma: PrismaService;
  let server: ReturnType<INestApplication['getHttpServer']>;

  const suffix = Date.now();
  const adminEmail = `e2e-audit-admin-${suffix}@test.local`;
  const PASSWORD = 'MotDePasseTemp1!';

  let adminId = '';
  let adminToken = '';
  const createdIds: string[] = [];

  const login = (identifier: string, password: string) =>
    request(server).post('/api/auth/login').send({ identifier, password });

  /// Entrées d'audit portant sur un compte donné, la plus récente d'abord.
  const auditFor = (entityId: string) =>
    prisma.auditLog.findMany({
      where: { entityType: 'User', entityId },
      orderBy: { createdAt: 'desc' },
    });

  /// Crée un compte via l'API et mémorise son id pour le nettoyage.
  const createUser = async (email: string, role: RoleCode = RoleCode.VENDEUR) => {
    const response = await request(server)
      .post('/api/users')
      .set('Authorization', `Bearer ${adminToken}`)
      .send({
        email,
        fullName: `Compte ${email}`,
        temporaryPassword: PASSWORD,
        roles: [role],
      })
      .expect(201);
    createdIds.push(response.body.id);
    return response.body;
  };

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

    const { AuthService } = await import('../src/auth/auth.service');
    const admin = await prisma.user.create({
      data: {
        email: adminEmail,
        fullName: 'Admin Audit',
        passwordHash: await AuthService.hashPassword(PASSWORD),
        mustChangePassword: false,
        roles: { connect: { code: RoleCode.ADMIN } },
      },
    });
    adminId = admin.id;
    createdIds.push(admin.id);

    adminToken = (await login(adminEmail, PASSWORD)).body.accessToken;
  });

  afterAll(async () => {
    await prisma.auditLog.deleteMany({
      where: { entityType: 'User', entityId: { in: createdIds } },
    });
    await prisma.auditLog.deleteMany({ where: { userId: { in: createdIds } } });
    await prisma.user.deleteMany({ where: { id: { in: createdIds } } });
    await app.close();
  });

  it('la création d’un compte est tracée, avec son auteur', async () => {
    const created = await createUser(`e2e-audit-new-${suffix}@test.local`);

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
    const created = await createUser(`e2e-audit-secret-${suffix}@test.local`);

    await request(server)
      .post(`/api/users/${created.id}/reset-password`)
      .set('Authorization', `Bearer ${adminToken}`)
      .send({ temporaryPassword: 'UnAutreMotDePasse9!' })
      .expect(201);

    const entries = await auditFor(created.id);
    const dump = JSON.stringify(entries);

    // Le journal est lisible par l'admin : il ne doit pas devenir une fuite.
    expect(dump).not.toContain(PASSWORD);
    expect(dump).not.toContain('UnAutreMotDePasse9!');
    expect(dump).not.toContain('passwordHash');
    expect(dump).not.toContain('$argon2');
  });

  it('un changement de RÔLE est tracé avec l’avant et l’après', async () => {
    const created = await createUser(`e2e-audit-role-${suffix}@test.local`);

    await request(server)
      .patch(`/api/users/${created.id}`)
      .set('Authorization', `Bearer ${adminToken}`)
      .send({ roles: [RoleCode.MAGASINIER] })
      .expect(200);

    const entries = await auditFor(created.id);
    const update = entries.find((e) => e.action === 'UPDATE');
    expect(update).toBeDefined();
    expect(update!.oldValue).toMatchObject({ roles: ['VENDEUR'] });
    expect(update!.newValue).toMatchObject({ roles: ['MAGASINIER'] });
  });

  it('une désactivation est tracée', async () => {
    const created = await createUser(`e2e-audit-off-${suffix}@test.local`);

    await request(server)
      .patch(`/api/users/${created.id}`)
      .set('Authorization', `Bearer ${adminToken}`)
      .send({ isActive: false })
      .expect(200);

    const update = (await auditFor(created.id)).find((e) => e.action === 'UPDATE');
    expect(update!.oldValue).toMatchObject({ isActive: true });
    expect(update!.newValue).toMatchObject({ isActive: false });
  });

  it('une réinitialisation de mot de passe est tracée sans le secret', async () => {
    const created = await createUser(`e2e-audit-reset-${suffix}@test.local`);

    await request(server)
      .post(`/api/users/${created.id}/reset-password`)
      .set('Authorization', `Bearer ${adminToken}`)
      .send({ temporaryPassword: 'NouveauTemporaire1!' })
      .expect(201);

    const update = (await auditFor(created.id)).find((e) => e.action === 'UPDATE');
    expect(update!.newValue).toMatchObject({
      operation: 'PASSWORD_RESET',
      mustChangePassword: true,
    });
    expect(JSON.stringify(update!.newValue)).not.toContain('NouveauTemporaire1!');
  });

  it('une révocation de sessions est tracée avec leur nombre', async () => {
    const created = await createUser(`e2e-audit-revoke-${suffix}@test.local`);
    // Deux connexions = deux sessions à révoquer.
    await login(created.email, PASSWORD);
    await login(created.email, PASSWORD);

    const response = await request(server)
      .post(`/api/users/${created.id}/revoke-sessions`)
      .set('Authorization', `Bearer ${adminToken}`)
      .expect(201);

    expect(response.body.revoked).toBe(2);
    const update = (await auditFor(created.id)).find(
      (e) => e.action === 'UPDATE' && (e.newValue as Record<string, unknown>)?.operation === 'REVOKE_SESSIONS',
    );
    expect(update!.newValue).toMatchObject({
      operation: 'REVOKE_SESSIONS',
      revokedSessions: 2,
    });
  });

  it('une mutation REFUSÉE n’écrit AUCUNE trace (atomicité)', async () => {
    const created = await createUser(`e2e-audit-refus-${suffix}@test.local`);
    const before = (await auditFor(created.id)).length;

    // Email déjà pris par l'admin → 409, rien ne doit être écrit.
    await request(server)
      .patch(`/api/users/${created.id}`)
      .set('Authorization', `Bearer ${adminToken}`)
      .send({ email: adminEmail })
      .expect(409);

    expect((await auditFor(created.id)).length).toBe(before);
  });

  it('désactiver le DERNIER admin actif est refusé, et ne trace rien', async () => {
    const before = (await auditFor(adminId)).length;

    // Le seed crée un autre admin : on le neutralise le temps du test pour que
    // le compte de test soit réellement le dernier admin actif.
    const otherAdmins = await prisma.user.findMany({
      where: {
        isActive: true,
        roles: { some: { code: RoleCode.ADMIN } },
        NOT: { id: adminId },
      },
      select: { id: true },
    });
    await prisma.user.updateMany({
      where: { id: { in: otherAdmins.map((u) => u.id) } },
      data: { isActive: false },
    });

    try {
      await request(server)
        .patch(`/api/users/${adminId}`)
        .set('Authorization', `Bearer ${adminToken}`)
        .send({ isActive: false })
        .expect(409);

      expect((await auditFor(adminId)).length).toBe(before);
    } finally {
      await prisma.user.updateMany({
        where: { id: { in: otherAdmins.map((u) => u.id) } },
        data: { isActive: true },
      });
    }
  });

  it('l’audit reste réservé à l’ADMIN', async () => {
    const created = await createUser(`e2e-audit-vendeur-${suffix}@test.local`);
    // Le compte est neuf : il doit d'abord changer son mot de passe.
    const session = await login(created.email, PASSWORD);
    const changed = await request(server)
      .post('/api/auth/change-password')
      .set('Authorization', `Bearer ${session.body.accessToken}`)
      .send({ currentPassword: PASSWORD, newPassword: 'MotDePasseVendeur1!' })
      .expect(200);

    const response = await request(server)
      .get('/api/audit-logs')
      .set('Authorization', `Bearer ${changed.body.accessToken}`);

    expect(response.status).toBe(403);
    expect(response.body.code).toBe('FORBIDDEN_ROLE');
  });
});
