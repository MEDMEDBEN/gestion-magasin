import * as request from 'supertest';
import { RoleCode } from '../src/common/auth.decorators';
import { PrismaService } from '../src/prisma/prisma.service';
import { createE2eApp, createTestUser, E2eApp } from './helpers/e2e-app';

/// Listes (revue générale L3/L4) : `?sort=` appliqué contre une liste blanche
/// (jamais ignoré en silence) et agrégats calculés PAR PAGE, pas par ligne.
describe('Listes : tri et agrégats par page (e2e)', () => {
  let e2e: E2eApp;
  let prisma: PrismaService;
  let server: E2eApp['server'];

  const suffix = Date.now();
  const PASSWORD = 'MotDePasseTemp1!';
  const userIds: string[] = [];
  const customerIds: string[] = [];
  const supplierIds: string[] = [];
  let token = '';

  const get = (url: string) =>
    request(server).get(url).set('Authorization', `Bearer ${token}`);

  beforeAll(async () => {
    e2e = await createE2eApp();
    prisma = e2e.prisma;
    server = e2e.server;
    const email = `e2e-lists-${suffix}@test.local`;
    const user = await createTestUser(prisma, {
      email,
      password: PASSWORD,
      roles: [RoleCode.ADMIN],
    });
    userIds.push(user.id);
    token = (
      await request(server)
        .post('/api/auth/login')
        .send({ identifier: email, password: PASSWORD })
        .expect(200)
    ).body.accessToken;
    for (const name of ['Zeta', 'Alpha', 'Mu']) {
      customerIds.push(
        (
          await prisma.customer.create({
            data: { name: `${name} liste ${suffix}` },
          })
        ).id,
      );
      supplierIds.push(
        (
          await prisma.supplier.create({
            data: { name: `${name} liste ${suffix}` },
          })
        ).id,
      );
    }
  });

  afterAll(async () => {
    await prisma.customer.deleteMany({ where: { id: { in: customerIds } } });
    await prisma.supplier.deleteMany({ where: { id: { in: supplierIds } } });
    await prisma.user.deleteMany({ where: { id: { in: userIds } } });
    await e2e.app.close();
  });

  it('tri inconnu → 400 sur chaque liste (jamais ignoré en silence)', async () => {
    for (const url of [
      '/api/sales',
      '/api/customers',
      '/api/suppliers',
      '/api/purchase-orders',
    ]) {
      const res = await get(`${url}?sort=passwordHash:asc`);
      expect({ url, status: res.status }).toEqual({ url, status: 400 });
    }
  });

  it('tri autorisé appliqué : clients et fournisseurs par nom décroissant', async () => {
    for (const url of ['/api/customers', '/api/suppliers']) {
      const res = await get(
        `${url}?q=liste ${suffix}&sort=name:desc&limit=10`,
      ).expect(200);
      expect(res.body.data.map((c: { name: string }) => c.name)).toEqual([
        `Zeta liste ${suffix}`,
        `Mu liste ${suffix}`,
        `Alpha liste ${suffix}`,
      ]);
    }
  });

  it('dette des clients d’une page : aucun agrégat par ligne', async () => {
    const perRow = jest.spyOn(prisma.customerPayment, 'aggregate');
    try {
      await get(`/api/customers?q=liste ${suffix}&limit=10`).expect(200);
      expect(perRow).not.toHaveBeenCalled();
    } finally {
      perRow.mockRestore();
    }
  });
});
