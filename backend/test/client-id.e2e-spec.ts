import * as request from 'supertest';
import { RoleCode } from '../src/common/auth.decorators';
import { PrismaService } from '../src/prisma/prisma.service';
import { createE2eApp, createTestUser, E2eApp } from './helpers/e2e-app';

/// `{ "id": null }` à la création : 400, jamais 500 (audit sécurité du
/// 2026-09-21). `@IsOptional()` laissait passer `null` jusqu'à Prisma sur TOUTES
/// les routes de création ; le correctif est un décorateur PARTAGÉ
/// (`ClientGeneratedId`). Ce test l'éprouve sur plusieurs modules à la fois,
/// chacun avec un corps par ailleurs VALIDE — sinon une autre erreur de
/// validation masquerait le défaut.
describe('Identifiant client null (e2e)', () => {
  let e2e: E2eApp;
  let prisma: PrismaService;
  let server: E2eApp['server'];
  let token = '';
  let adminId = '';
  const suffix = Date.now();
  const PASSWORD = 'MotDePasseTemp1!';

  beforeAll(async () => {
    e2e = await createE2eApp();
    prisma = e2e.prisma;
    server = e2e.server;
    const email = `e2e-clientid-${suffix}@test.local`;
    adminId = (
      await createTestUser(prisma, {
        email,
        password: PASSWORD,
        roles: [RoleCode.ADMIN],
      })
    ).id;
    token = (
      await request(server)
        .post('/api/auth/login')
        .send({ identifier: email, password: PASSWORD })
        .expect(200)
    ).body.accessToken;
  });

  afterAll(async () => {
    await prisma.auditLog.deleteMany({ where: { userId: adminId } });
    await prisma.user.deleteMany({ where: { id: adminId } });
    await e2e.app.close();
  });

  const cases: [string, object][] = [
    ['/api/suppliers', { name: `Fournisseur ${suffix}` }],
    ['/api/customers', { name: `Client ${suffix}` }],
    [
      '/api/products',
      { sku: `E2E-NULLID-${suffix}`, name: 'Produit id nul', unit: 'PIECE' },
    ],
  ];

  it.each(cases)('%s : `id: null` → 400', async (url, body) => {
    const response = await request(server)
      .post(url)
      .set('Authorization', `Bearer ${token}`)
      .send({ ...body, id: null });
    expect(response.status).toBe(400);
    expect(response.body.code).toBe('VALIDATION_FAILED');
  });
});
