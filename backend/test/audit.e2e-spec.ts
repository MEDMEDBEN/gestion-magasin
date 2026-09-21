import * as request from 'supertest';
import { RoleCode } from '../src/common/auth.decorators';
import { localDate } from '../src/common/document-number';
import { PrismaService } from '../src/prisma/prisma.service';
import { createE2eApp, createTestUser, E2eApp } from './helpers/e2e-app';

/// Historique global (P0 n°11, spec §24) — lecture du journal d'audit.
///
/// Éprouvé en priorité : réservé à l'ADMIN, relu EN BASE (un admin rétrogradé
/// perd la vue tout de suite), aucune route pour modifier ou effacer une
/// entrée, et aucun secret dans ce qui est tracé.
describe('Historique / audit (e2e)', () => {
  let e2e: E2eApp;
  let prisma: PrismaService;
  let server: E2eApp['server'];

  const suffix = Date.now();
  const PASSWORD = 'MotDePasseTemp1!';
  const userIds: string[] = [];
  const productIds: string[] = [];
  const ids: Record<string, string> = {};
  const tokens: Record<string, string> = {};

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

  const login = async (key: string, role: RoleCode) => {
    const email = `e2e-audit-${key}-${suffix}@test.local`;
    const user = await createTestUser(prisma, {
      email,
      password: PASSWORD,
      roles: [role],
      fullName: `Auditeur ${key}`,
    });
    userIds.push(user.id);
    ids[key] = user.id;
    tokens[key] = (
      await request(server)
        .post('/api/auth/login')
        .send({ identifier: email, password: PASSWORD })
        .expect(200)
    ).body.accessToken;
  };

  /// Produit créé PAR l'admin : laisse une entrée CREATE à son nom.
  const tracedProduct = async (admin = 'admin') => {
    const created = (
      await as(tokens[admin])
        .post('/api/products')
        .send({
          sku: `E2E-AUD-${suffix}-${productIds.length}`,
          name: `Produit audité ${productIds.length}`,
          unit: 'PIECE',
        })
        .expect(201)
    ).body;
    productIds.push(created.id);
    return created.id as string;
  };

  beforeAll(async () => {
    e2e = await createE2eApp();
    prisma = e2e.prisma;
    server = e2e.server;
    await login('admin', RoleCode.ADMIN);
    await login('admin2', RoleCode.ADMIN);
    await login('vendeur', RoleCode.VENDEUR);
    await login('magasinier', RoleCode.MAGASINIER);
  });

  afterAll(async () => {
    await prisma.auditLog.deleteMany({
      where: {
        OR: [
          { userId: { in: userIds } },
          { entityId: { in: [...productIds, ...userIds] } },
        ],
      },
    });
    await prisma.product.deleteMany({ where: { id: { in: productIds } } });
    await prisma.user.deleteMany({ where: { id: { in: userIds } } });
    await e2e.app.close();
  });

  it('l’admin lit le journal : qui, quoi, sur quel objet, avant/après', async () => {
    const productId = await tracedProduct();
    await as(tokens.admin)
      .patch(`/api/products/${productId}`)
      .send({ name: 'Produit audité — renommé' })
      .expect(200);

    const page = (
      await as(tokens.admin)
        .get(`/api/audit-logs?entityId=${productId}`)
        .expect(200)
    ).body;
    // Du plus récent au plus ancien.
    expect(page.data.map((e: { action: string }) => e.action)).toEqual([
      'UPDATE',
      'CREATE',
    ]);
    const update = page.data[0];
    expect(update).toMatchObject({
      userId: ids.admin,
      userName: 'Auditeur admin',
      entityType: 'Product',
      entityId: productId,
    });
    expect(update.oldValue.name).toBe('Produit audité 0');
    expect(update.newValue.name).toBe('Produit audité — renommé');
    expect(page.meta.total).toBe(2);
  });

  it('réservé à l’ADMIN : vendeur et magasinier refusés', async () => {
    for (const key of ['vendeur', 'magasinier']) {
      const refused = await as(tokens[key]).get('/api/audit-logs').expect(403);
      expect(refused.body.code).toBe('FORBIDDEN_ROLE');
    }
  });

  it('un admin RÉTROGRADÉ perd la vue du journal immédiatement (relu en base)', async () => {
    // Son jeton, lui, dit encore ADMIN pour quelques minutes : c'est la base
    // qui doit faire foi pour une lecture aussi sensible.
    await as(tokens.admin2).get('/api/audit-logs?limit=1').expect(200);
    await prisma.user.update({
      where: { id: ids.admin2 },
      data: { roles: { set: [{ code: RoleCode.VENDEUR }] } },
    });
    await as(tokens.admin2).get('/api/audit-logs?limit=1').expect(403);
  });

  it('compte désactivé, session révoquée, mot de passe à changer : refusés', async () => {
    // Vérifiés à la main par l'audit sécurité : on les FIGE, pour qu'un retrait
    // futur de `@RequireFreshAccess()` fasse échouer un test.
    await login('desactive', RoleCode.ADMIN);
    await prisma.user.update({
      where: { id: ids.desactive },
      data: { isActive: false },
    });
    await as(tokens.desactive).get('/api/audit-logs?limit=1').expect(403);

    await login('revoque', RoleCode.ADMIN);
    await prisma.refreshToken.updateMany({
      where: { userId: ids.revoque },
      data: { revokedAt: new Date() },
    });
    await as(tokens.revoque).get('/api/audit-logs?limit=1').expect(401);

    await login('achanger', RoleCode.ADMIN);
    await prisma.user.update({
      where: { id: ids.achanger },
      data: { mustChangePassword: true },
    });
    await as(tokens.achanger).get('/api/audit-logs?limit=1').expect(403);

    await request(server).get('/api/audit-logs').expect(401);
  });

  it('journal IMMUABLE : aucune route pour écrire, modifier ou effacer', async () => {
    const productId = await tracedProduct();
    const entry = await prisma.auditLog.findFirstOrThrow({
      where: { entityId: productId },
    });
    // Chaque requête est construite AU MOMENT de l'envoyer : supertest ouvre et
    // ferme un port par requête.
    for (const call of [
      () => as(tokens.admin).post('/api/audit-logs').send({}),
      () => as(tokens.admin).patch(`/api/audit-logs/${entry.id}`).send({}),
      () => as(tokens.admin).delete(`/api/audit-logs/${entry.id}`),
    ]) {
      const response = await call();
      expect(response.status).toBe(404);
    }
    expect(await prisma.auditLog.count({ where: { id: entry.id } })).toBe(1);
  });

  it('aucun secret tracé : la création d’un compte ne laisse aucun mot de passe', async () => {
    const created = (
      await as(tokens.admin)
        .post('/api/users')
        .send({
          email: `e2e-audit-nouveau-${suffix}@test.local`,
          fullName: 'Nouveau venu',
          temporaryPassword: 'SecretTemporaire1!',
          roles: ['VENDEUR'],
        })
        .expect(201)
    ).body;
    userIds.push(created.id);

    const trail = (
      await as(tokens.admin)
        .get(`/api/audit-logs?entityType=User&entityId=${created.id}`)
        .expect(200)
    ).body;
    expect(trail.data.length).toBeGreaterThan(0);
    const serialized = JSON.stringify(trail);
    expect(serialized).not.toContain('SecretTemporaire1!');
    expect(serialized.toLowerCase()).not.toContain('passwordhash');
    expect(serialized.toLowerCase()).not.toMatch(/"password"/);
  });

  it('filtres : par membre, par action, par type, par période (jour d’Alger)', async () => {
    const productId = await tracedProduct();

    const byMember = (
      await as(tokens.admin)
        .get(`/api/audit-logs?userId=${ids.admin}&limit=200`)
        .expect(200)
    ).body.data;
    expect(byMember.length).toBeGreaterThan(0);
    expect(
      byMember.every((e: { userId: string }) => e.userId === ids.admin),
    ).toBe(true);

    const creates = (
      await as(tokens.admin)
        .get(
          `/api/audit-logs?action=CREATE&entityType=Product&entityId=${productId}`,
        )
        .expect(200)
    ).body.data;
    expect(creates).toHaveLength(1);

    const today = localDate(new Date());
    const onlyToday = (
      await as(tokens.admin)
        .get(`/api/audit-logs?entityId=${productId}&from=${today}&to=${today}`)
        .expect(200)
    ).body.data;
    expect(onlyToday).toHaveLength(1);

    // Hier seulement : l'entrée d'aujourd'hui n'y est pas.
    const yesterday = localDate(new Date(Date.now() - 86_400_000));
    const before = (
      await as(tokens.admin)
        .get(`/api/audit-logs?entityId=${productId}&to=${yesterday}`)
        .expect(200)
    ).body.data;
    expect(before).toHaveLength(0);
  });

  it('entrées forgées : 400, jamais 500', async () => {
    for (const url of [
      '/api/audit-logs?action=constructor',
      '/api/audit-logs?action=toString',
      '/api/audit-logs?entityType=Product%27%3B--',
      '/api/audit-logs?entityId=pas-un-uuid',
      '/api/audit-logs?sort=ipAddress:asc',
      '/api/audit-logs?sort=oldValue:asc',
      '/api/audit-logs?from=2026-W05',
      '/api/audit-logs?from=2026-02-30',
      '/api/audit-logs?from=2026-09-21T10:00:00Z',
      '/api/audit-logs?from=2026-09-22&to=2026-09-21',
      '/api/audit-logs?page=1e308',
      '/api/audit-logs?page=99999999999999999999',
    ]) {
      const response = await as(tokens.admin).get(url);
      expect([url, response.status]).toEqual([url, 400]);
    }
  });
});
