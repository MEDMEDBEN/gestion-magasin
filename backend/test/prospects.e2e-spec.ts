import { randomUUID } from 'crypto';
import * as request from 'supertest';
import { RoleCode } from '../src/common/auth.decorators';
import { PrismaService } from '../src/prisma/prisma.service';
import { createE2eApp, createTestUser, E2eApp } from './helpers/e2e-app';

/// Contact clients ciblé (P2 n°23, spec §28) : pour un nouveau produit, les
/// clients ACTIFS qui ont acheté sa catégorie ou une catégorie sœur, du plus
/// fidèle au moins fidèle, avec un message à modèle fixe. ADMIN seul.
describe('Clients à prévenir (e2e)', () => {
  let e2e: E2eApp;
  let prisma: PrismaService;
  let server: E2eApp['server'];

  const suffix = Date.now();
  const PASSWORD = 'MotDePasseTemp1!';
  const tokens: Record<string, string> = {};
  const userIds: string[] = [];
  const productIds: string[] = [];
  const customerIds: string[] = [];
  const categoryIds: string[] = [];
  let magasinId = '';
  let counter = 0;

  const as = (token: string) => ({
    get: (url: string) =>
      request(server).get(url).set('Authorization', `Bearer ${token}`),
  });
  const category = async (parentId?: string) => {
    const c = await prisma.category.create({
      data: { name: `Cat prospects ${suffix}-${++counter}`, parentId },
    });
    categoryIds.push(c.id);
    return c.id;
  };
  const product = async (categoryId: string | null) => {
    const n = ++counter;
    const p = await prisma.product.create({
      data: {
        sku: `E2E-PROS-${suffix}-${n}`,
        barcode: `E2E-PROS-BC-${suffix}-${n}`,
        name: `Produit prospects ${n}`,
        categoryId,
      },
    });
    productIds.push(p.id);
    return p;
  };
  const customer = async (name: string, isActive = true) => {
    const c = await prisma.customer.create({
      data: { name: `${name} ${suffix}`, phone: '0550 00 00 01', isActive },
    });
    customerIds.push(c.id);
    return c;
  };
  /// Vente validée d'un produit à un client (ou au comptoir : `null`), écrite
  /// en base (on éprouve la sélection, pas la vente).
  const sold = (
    customerId: string | null,
    productId: string,
    soldAt = new Date(),
  ) =>
    prisma.sale.create({
      data: {
        number: `E2E-PROS-${suffix}-${++counter}`,
        userId: userIds[0],
        locationId: magasinId,
        customerId,
        totalHt: 1000,
        totalTax: 0,
        totalTtc: 1000,
        paidAmount: 1000,
        soldAt,
        lines: {
          create: [
            {
              productId,
              quantity: '1',
              unitPriceHt: 1000,
              lineTotalHt: 1000,
              lineTaxAmount: 0,
              lineTotalTtc: 1000,
            },
          ],
        },
      },
    });

  beforeAll(async () => {
    e2e = await createE2eApp();
    prisma = e2e.prisma;
    server = e2e.server;
    magasinId = (
      await prisma.location.findFirstOrThrow({ where: { type: 'MAGASIN' } })
    ).id;
    for (const [key, role] of [
      ['admin', RoleCode.ADMIN],
      ['vendeur', RoleCode.VENDEUR],
    ] as const) {
      const email = `e2e-pros-${key}-${suffix}@test.local`;
      const user = await createTestUser(prisma, {
        email,
        password: PASSWORD,
        roles: [role],
      });
      userIds.push(user.id);
      tokens[key] = (
        await request(server)
          .post('/api/auth/login')
          .send({ identifier: email, password: PASSWORD })
          .expect(200)
      ).body.accessToken;
    }
  });

  afterAll(async () => {
    await prisma.sale.deleteMany({ where: { userId: { in: userIds } } });
    await prisma.product.deleteMany({ where: { id: { in: productIds } } });
    await prisma.customer.deleteMany({ where: { id: { in: customerIds } } });
    await prisma.category.deleteMany({
      where: { id: { in: categoryIds }, parentId: { not: null } },
    });
    await prisma.category.deleteMany({ where: { id: { in: categoryIds } } });
    await prisma.auditLog.deleteMany({ where: { userId: { in: userIds } } });
    await prisma.user.deleteMany({ where: { id: { in: userIds } } });
    await e2e.app.close();
  });

  it('catégorie et sœurs, clients actifs, du plus fidèle ; message à son nom', async () => {
    const parent = await category();
    const [cables, gaines, other] = [
      await category(parent),
      await category(parent),
      await category(),
    ];
    const nouveau = await product(cables);
    const [sister, unrelated] = [await product(gaines), await product(other)];
    const fidele = await customer('Fidèle');
    const occasionnel = await customer('Occasionnel');
    const ailleurs = await customer('Ailleurs');
    const inactif = await customer('Inactif', false);
    await sold(fidele.id, sister.id);
    await sold(fidele.id, sister.id);
    await sold(occasionnel.id, sister.id);
    await sold(ailleurs.id, unrelated.id);
    await sold(inactif.id, sister.id);
    // Vente comptoir dans la catégorie : aucun client à prévenir.
    await sold(null, sister.id);

    const list = (
      await as(tokens.admin)
        .get(`/api/products/${nouveau.id}/prospects`)
        .expect(200)
    ).body as { customerId: string; purchases: number; message: string }[];
    expect(list.map((p) => [p.customerId, p.purchases])).toEqual([
      [fidele.id, 2],
      [occasionnel.id, 1],
    ]);
    expect(list[0].message).toContain(`Bonjour ${fidele.name},`);
    expect(list[0].message).toContain(nouveau.name);
  });

  /// Revue 21n : un produit rangé à la RACINE couvre aussi ses sous-catégories ;
  /// un client injoignable (ni téléphone ni e-mail) n'est pas listé ; une vente
  /// annulée ne compte pas.
  it('racine : sous-catégories comprises ; injoignable et annulée exclus', async () => {
    const famille = await category();
    const sous = await category(famille);
    const nouveau = await product(famille);
    const vendu = await product(sous);
    const joignable = await customer('Joignable');
    const muet = await prisma.customer.create({
      data: { name: `Muet ${suffix}` },
    });
    customerIds.push(muet.id);
    const annule = await customer('Annulé');
    await sold(joignable.id, vendu.id);
    await sold(muet.id, vendu.id);
    const cancelled = await sold(annule.id, vendu.id);
    await prisma.sale.update({
      where: { id: cancelled.id },
      data: { status: 'ANNULEE' },
    });

    const list = (
      await as(tokens.admin)
        .get(`/api/products/${nouveau.id}/prospects`)
        .expect(200)
    ).body as { customerId: string }[];
    expect(list.map((p) => p.customerId)).toEqual([joignable.id]);
  });

  it('ADMIN seul ; produit sans catégorie : 422 ; inconnu : 404', async () => {
    const orphan = await product(null);
    await as(tokens.vendeur)
      .get(`/api/products/${orphan.id}/prospects`)
      .expect(403);
    await as(tokens.admin)
      .get(`/api/products/${orphan.id}/prospects`)
      .expect(422);
    await as(tokens.admin)
      .get(`/api/products/${randomUUID()}/prospects`)
      .expect(404);
  });
});
