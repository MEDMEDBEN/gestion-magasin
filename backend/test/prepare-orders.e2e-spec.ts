import * as request from 'supertest';
import { RoleCode } from '../src/common/auth.decorators';
import { PrismaService } from '../src/prisma/prisma.service';
import { createE2eApp, createTestUser, E2eApp } from './helpers/e2e-app';

/// Commandes préparées automatiquement (P2 n°22, spec §28, sans IA).
///
/// Éprouvé : une commande BROUILLON par fournisseur principal, au dernier prix
/// d'achat ; les produits sans fournisseur (ou fournisseur désactivé) sont
/// rendus à part ; rien n'est confirmé ; message à modèle fixe ; mêmes gardes
/// que la commande fournisseur.
describe('Commandes préparées (e2e)', () => {
  let e2e: E2eApp;
  let prisma: PrismaService;
  let server: E2eApp['server'];

  const suffix = Date.now();
  const PASSWORD = 'MotDePasseTemp1!';
  const tokens: Record<string, string> = {};
  const userIds: string[] = [];
  const productIds: string[] = [];
  const supplierIds: string[] = [];
  let counter = 0;

  const as = (token: string) => ({
    get: (url: string) =>
      request(server).get(url).set('Authorization', `Bearer ${token}`),
    post: (url: string) =>
      request(server).post(url).set('Authorization', `Bearer ${token}`),
  });
  const supplier = async (isActive = true) => {
    const created = await prisma.supplier.create({
      data: {
        name: `Fournisseur prépa ${suffix}-${++counter}`,
        contactName: 'M. Rahmani',
        email: 'achats@fournisseur.dz',
        phone: '0550 11 22 33',
        isActive,
      },
    });
    supplierIds.push(created.id);
    return created.id;
  };
  const product = async (mainSupplierId: string | null, cost?: number) => {
    const n = ++counter;
    const created = await prisma.product.create({
      data: {
        sku: `E2E-PREP-${suffix}-${n}`,
        barcode: `E2E-PREP-BC-${suffix}-${n}`,
        name: `Produit prépa ${n}`,
        mainSupplierId,
        lastPurchasePriceHt: cost,
      },
    });
    productIds.push(created.id);
    return created;
  };
  const prepare = (token: string, lines: object[]) =>
    as(token).post('/api/replenishment/orders').send({ lines });

  beforeAll(async () => {
    e2e = await createE2eApp();
    prisma = e2e.prisma;
    server = e2e.server;
    for (const [key, role] of [
      ['admin', RoleCode.ADMIN],
      ['magasinier', RoleCode.MAGASINIER],
      ['vendeur', RoleCode.VENDEUR],
    ] as const) {
      const email = `e2e-prep-${key}-${suffix}@test.local`;
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
    await prisma.purchaseOrder.deleteMany({
      where: { supplierId: { in: supplierIds } },
    });
    await prisma.product.deleteMany({ where: { id: { in: productIds } } });
    await prisma.supplier.deleteMany({ where: { id: { in: supplierIds } } });
    await prisma.auditLog.deleteMany({ where: { userId: { in: userIds } } });
    await prisma.user.deleteMany({ where: { id: { in: userIds } } });
    await e2e.app.close();
  });

  it('une commande BROUILLON par fournisseur, au dernier prix ; sans fournisseur : à part', async () => {
    const [a, b, off] = [
      await supplier(),
      await supplier(),
      await supplier(false),
    ];
    const p1 = await product(a, 120000);
    const p2 = await product(a);
    const p3 = await product(b, 5000);
    const orphan = await product(null);
    const retired = await product(off, 100);

    const res = await prepare(tokens.magasinier, [
      { productId: p1.id, quantity: '10' },
      { productId: p2.id, quantity: '2.5' },
      { productId: p3.id, quantity: '4' },
      { productId: orphan.id, quantity: '1' },
      { productId: retired.id, quantity: '1' },
    ]).expect(201);

    expect(res.body.withoutSupplier.sort()).toEqual(
      [orphan.name, retired.name].sort(),
    );
    expect(res.body.orders).toHaveLength(2);
    // p2 n'a pas de prix d'achat connu : signalé.
    expect(res.body.unpricedLines).toBe(1);
    const orders = await prisma.purchaseOrder.findMany({
      where: { id: { in: res.body.orders.map((o: { id: string }) => o.id) } },
      include: { lines: true },
    });
    const ofA = orders.find((o) => o.supplierId === a)!;
    expect(ofA.status).toBe('BROUILLON');
    expect(
      ofA.lines
        .map((l) => [l.productId, l.orderedQuantity.toFixed(3), l.unitPriceHt])
        .sort(),
    ).toEqual(
      [
        [p1.id, '10.000', 120000],
        [p2.id, '2.500', 0],
      ].sort(),
    );
    expect(orders.find((o) => o.supplierId === b)!.status).toBe('BROUILLON');
  });

  it('message au fournisseur : modèle fixe, une ligne par produit, coordonnées', async () => {
    const s = await supplier();
    const p = await product(s, 100);
    const prepared = (
      await prepare(tokens.admin, [
        { productId: p.id, quantity: '12.5' },
      ]).expect(201)
    ).body.orders[0];
    const msg = (
      await as(tokens.magasinier)
        .get(`/api/purchase-orders/${prepared.id}/message`)
        .expect(200)
    ).body;
    expect(msg.text).toBe(
      [
        'Bonjour M. Rahmani,',
        'Nous souhaitons commander :',
        `- 12,5 pce de ${p.name} (réf. ${p.sku})`,
        'Merci de confirmer.',
        `Commande ${prepared.number}`,
      ].join('\n'),
    );
    expect(msg).toMatchObject({
      email: 'achats@fournisseur.dz',
      phone: '0550 11 22 33',
    });
    // Annulée : plus rien à commander.
    await prisma.purchaseOrder.update({
      where: { id: prepared.id },
      data: { status: 'ANNULEE' },
    });
    await as(tokens.magasinier)
      .get(`/api/purchase-orders/${prepared.id}/message`)
      .expect(409);
  });

  it('gardes et validations : vendeur refusé, doublon et quantité nulle refusés', async () => {
    const s = await supplier();
    const p = await product(s);
    await prepare(tokens.vendeur, [{ productId: p.id, quantity: '1' }]).expect(
      403,
    );
    await prepare(tokens.admin, [
      { productId: p.id, quantity: '1' },
      { productId: p.id, quantity: '2' },
    ]).expect(422);
    await prepare(tokens.admin, [{ productId: p.id, quantity: '0' }]).expect(
      422,
    );
    await prepare(tokens.admin, []).expect(400);
  });
});
