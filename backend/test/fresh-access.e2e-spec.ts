import * as request from 'supertest';
import { RoleCode } from '../src/common/auth.decorators';
import { PrismaService } from '../src/prisma/prisma.service';
import { createE2eApp, createTestUser, E2eApp } from './helpers/e2e-app';

/// Guard UNIQUE (revue générale S1) : TOUTE écriture authentifiée relit le
/// compte en base. Un compte désactivé après sa connexion ne peut plus rien
/// écrire, même avec un access token encore valable 15 min — y compris sur les
/// routes qui n'avaient jamais porté de décorateur dédié.
describe('Droits relus en base sur toute écriture (e2e)', () => {
  let e2e: E2eApp;
  let prisma: PrismaService;
  let server: E2eApp['server'];

  const suffix = Date.now();
  const PASSWORD = 'MotDePasseTemp1!';
  const userIds: string[] = [];
  let token = '';
  let magasinId = '';

  beforeAll(async () => {
    e2e = await createE2eApp();
    prisma = e2e.prisma;
    server = e2e.server;
    magasinId = (
      await prisma.location.findFirstOrThrow({ where: { type: 'MAGASIN' } })
    ).id;
    const email = `e2e-fresh-${suffix}@test.local`;
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
  });

  afterAll(async () => {
    await prisma.auditLog.deleteMany({ where: { userId: { in: userIds } } });
    await prisma.refreshToken.deleteMany({
      where: { userId: { in: userIds } },
    });
    await prisma.user.deleteMany({ where: { id: { in: userIds } } });
    await e2e.app.close();
  });

  it('compte désactivé : chaque écriture refusée (403 ACCOUNT_DISABLED), la lecture reste possible', async () => {
    const zero = '00000000-0000-4000-8000-000000000000';
    await prisma.user.update({
      where: { id: userIds[0] },
      data: { isActive: false },
    });

    const writes: [string, string, object][] = [
      [
        'post',
        '/api/cash-sessions',
        { locationId: magasinId, openingFloat: 0 },
      ],
      ['post', `/api/cash-sessions/${zero}/close`, { countedAmount: 0 }],
      ['post', '/api/payments/customer', { customerId: zero, amount: 1 }],
      ['post', '/api/products', { sku: 'X', name: 'Produit', unit: 'PIECE' }],
      ['patch', `/api/products/${zero}`, { allowBackorder: true }],
      ['post', '/api/categories', { name: 'Catégorie' }],
      ['post', '/api/locations', { parentId: zero, zone: 'A' }],
    ];
    for (const [method, url, body] of writes) {
      const res = await (
        request(server) as unknown as Record<
          string,
          (u: string) => request.Test
        >
      )
        [method](url)
        .set('Authorization', `Bearer ${token}`)
        .send(body);
      expect({ url, status: res.status, code: res.body.code }).toEqual({
        url,
        status: 403,
        code: 'ACCOUNT_DISABLED',
      });
    }

    // Lecture : le token reste valable pour lire jusqu'à son expiration.
    await request(server)
      .get('/api/products')
      .set('Authorization', `Bearer ${token}`)
      .expect(200);
  });
});
