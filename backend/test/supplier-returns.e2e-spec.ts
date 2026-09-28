import { randomUUID } from 'crypto';
import * as request from 'supertest';
import { RoleCode } from '../src/common/auth.decorators';
import { PrismaService } from '../src/prisma/prisma.service';
import { createE2eApp, createTestUser, E2eApp } from './helpers/e2e-app';

/// Retours fournisseur (P1 bis n°21l, partie 2). Éprouvé : stock sorti par le
/// journal (règle 2), dette réduite au prorata du TTC RÉCEPTIONNÉ (jamais un
/// prix saisi), quantité bornée par le reçu non renvoyé, jamais de stock
/// négatif, rejouable sans double effet, mêmes droits que la réception.
describe('Retours fournisseur (e2e)', () => {
  let e2e: E2eApp;
  let prisma: PrismaService;
  let server: E2eApp['server'];

  const suffix = Date.now();
  const PASSWORD = 'MotDePasseTemp1!';
  const userIds: string[] = [];
  const productIds: string[] = [];
  const tokens: Record<string, string> = {};
  let supplierId = '';
  let depotId = '';
  let counter = 0;

  const as = (token: string) => ({
    get: (url: string) =>
      request(server).get(url).set('Authorization', `Bearer ${token}`),
    post: (url: string) =>
      request(server).post(url).set('Authorization', `Bearer ${token}`),
  });
  const stockOf = async (productId: string) =>
    (
      await prisma.stock.findFirst({
        where: { productId, locationId: depotId },
      })
    )?.quantity.toFixed(3) ?? '0.000';
  const debt = async () =>
    (await as(tokens.admin).get(`/api/suppliers/${supplierId}`).expect(200))
      .body.balanceDue as number;

  /// 10 unités reçues à 1 200,00 HT (TVA 19 %) : 14 280,00 TTC de dette.
  const received = async (backorder = false) => {
    const n = ++counter;
    const tva = await prisma.taxRate.findFirstOrThrow({ where: { rate: 19 } });
    const product = await prisma.product.create({
      data: {
        sku: `E2E-RF-${suffix}-${n}`,
        barcode: `E2E-RF-BC-${suffix}-${n}`,
        name: `Produit retour fournisseur ${n}`,
        taxRateId: tva.id,
        allowBackorder: backorder,
      },
    });
    productIds.push(product.id);
    const orderId = await receive(product.id, '10', 120000);
    return { productId: product.id, orderId };
  };
  /// Commande confirmée puis réceptionnée en entier au dépôt.
  const receive = async (
    productId: string,
    quantity: string,
    unitPriceHt: number,
  ) => {
    const order = (
      await as(tokens.magasinier)
        .post('/api/purchase-orders')
        .send({
          supplierId,
          lines: [{ productId, orderedQuantity: quantity, unitPriceHt }],
        })
        .expect(201)
    ).body;
    const confirmed = (
      await as(tokens.admin)
        .post(`/api/purchase-orders/${order.id}/confirm`)
        .send({ expectedUpdatedAt: order.updatedAt })
        .expect(200)
    ).body;
    await as(tokens.magasinier)
      .post('/api/receptions')
      .send({
        purchaseOrderId: order.id,
        supplierId,
        locationId: depotId,
        lines: [
          {
            productId,
            purchaseLineId: confirmed.lines[0].id,
            receivedQuantity: quantity,
            unitPriceHt,
          },
        ],
      })
      .expect(201);
    return order.id as string;
  };
  const sendBack = (
    productId: string,
    quantity: string,
    extra: Record<string, unknown> = {},
    token = tokens.magasinier,
  ) =>
    as(token)
      .post('/api/supplier-returns')
      .send({
        id: randomUUID(),
        supplierId,
        locationId: depotId,
        lines: [{ productId, quantity }],
        reason: 'Lot défectueux',
        ...extra,
      });

  beforeAll(async () => {
    e2e = await createE2eApp();
    prisma = e2e.prisma;
    server = e2e.server;
    for (const [key, role] of [
      ['admin', RoleCode.ADMIN],
      ['magasinier', RoleCode.MAGASINIER],
      ['vendeur', RoleCode.VENDEUR],
    ] as const) {
      const email = `e2e-rf-${key}-${suffix}@test.local`;
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
    supplierId = (
      await prisma.supplier.create({
        data: { name: `Fournisseur retours ${suffix}` },
      })
    ).id;
    depotId = (
      await prisma.location.findFirstOrThrow({ where: { type: 'DEPOT' } })
    ).id;
  });

  afterAll(async () => {
    await prisma.supplierReturn.deleteMany({ where: { supplierId } });
    const receptions = await prisma.reception.findMany({
      where: { supplierId },
      select: { id: true },
    });
    await prisma.receptionLine.deleteMany({
      where: { receptionId: { in: receptions.map((r) => r.id) } },
    });
    await prisma.reception.deleteMany({ where: { supplierId } });
    await prisma.purchaseOrder.deleteMany({ where: { supplierId } });
    await prisma.stockMovement.deleteMany({
      where: { productId: { in: productIds } },
    });
    await prisma.stock.deleteMany({ where: { productId: { in: productIds } } });
    await prisma.product.deleteMany({ where: { id: { in: productIds } } });
    await prisma.supplier.deleteMany({ where: { id: supplierId } });
    await prisma.auditLog.deleteMany({ where: { userId: { in: userIds } } });
    await prisma.user.deleteMany({ where: { id: { in: userIds } } });
    await e2e.app.close();
  });

  it('stock sorti, dette réduite au prorata du reçu, numéro RF, PDF, audit', async () => {
    const { productId } = await received();
    const before = await debt();
    expect(await stockOf(productId)).toBe('10.000');

    const res = await sendBack(productId, '3').expect(201);
    expect(res.body.number).toMatch(/^RF-\d{4}-\d{5}$/);
    // 3 × 1 200,00 = 3 600,00 HT ; 3/10 de 14 280,00 TTC = 4 284,00.
    expect(res.body).toMatchObject({ totalHt: 360000, totalTtc: 428400 });
    expect(await stockOf(productId)).toBe('7.000');
    expect(await debt()).toBe(before - 428400);

    const pdf = await as(tokens.admin)
      .get(`/api/supplier-returns/${res.body.id}/pdf`)
      .expect(200);
    expect(pdf.headers['content-type']).toBe('application/pdf');
    const listed = await as(tokens.magasinier)
      .get(`/api/suppliers/${supplierId}/returns`)
      .expect(200);
    expect(listed.body.map((r: { id: string }) => r.id)).toContain(res.body.id);
    expect(
      await prisma.auditLog.count({
        where: { entityType: 'SupplierReturn', entityId: res.body.id },
      }),
    ).toBe(1);
  });

  it('borné par le reçu non renvoyé ; un produit jamais reçu de lui : refusé', async () => {
    const { productId } = await received();
    await sendBack(productId, '6').expect(201);
    await sendBack(productId, '4.5').expect(422);
    await sendBack(productId, '4').expect(201);
    await sendBack(productId, '0.5').expect(422);
    const stranger = await prisma.product.create({
      data: {
        sku: `E2E-RF-${suffix}-X`,
        barcode: `E2E-RF-BC-${suffix}-X`,
        name: 'Jamais reçu',
      },
    });
    productIds.push(stranger.id);
    await sendBack(stranger.id, '1').expect(422);
  });

  /// « Vente sans stock » ne vaut pas pour un renvoi : on ne rend que ce qu'on
  /// a (ici, 7 des 10 reçus ont quitté le dépôt).
  it('jamais de stock négatif, même « vente sans stock autorisée »', async () => {
    const { productId } = await received(true);
    const stock = await prisma.stock.findFirstOrThrow({
      where: { productId, locationId: depotId },
    });
    await prisma.stock.update({
      where: { id: stock.id },
      data: { quantity: '3' },
    });
    const res = await sendBack(productId, '5').expect(422);
    expect(res.body.code).toBe('STOCK_NEGATIVE');
  });

  it('rejeu de la même clé : un seul retour ; autre contenu : 409', async () => {
    const { productId } = await received();
    const key = { clientMutationId: randomUUID() };
    const first = await sendBack(productId, '1', key).expect(201);
    const again = await sendBack(productId, '1', key).expect(201);
    expect(again.body.id).toBe(first.body.id);
    expect(await stockOf(productId)).toBe('9.000');
    await sendBack(productId, '2', key).expect(409);
  });

  it('droits de la réception : le vendeur ne renvoie rien', async () => {
    const { productId } = await received();
    await sendBack(productId, '1', {}, tokens.vendeur).expect(403);
    await as(tokens.vendeur)
      .get(`/api/suppliers/${supplierId}/returns`)
      .expect(403);
    await sendBack(productId, '1', { reason: '  ' }).expect(400);
  });

  /// Audit 21l : chaque unité vaut ce que SA réception a ajouté à la dette
  /// (les plus récentes d'abord) — jamais tout au dernier prix.
  it('prix changé entre deux réceptions : chaque lot à son prix', async () => {
    const { productId } = await received(); // 10 u. à 1 200,00 HT
    await receive(productId, '1', 1200000); // 1 u. à 12 000,00 HT
    const before = await debt();
    const res = await sendBack(productId, '11').expect(201);
    // 1 × 12 000,00 + 10 × 1 200,00 = 24 000,00 HT ; TTC 19 %.
    expect(res.body).toMatchObject({ totalHt: 2400000, totalTtc: 2856000 });
    expect(await debt()).toBe(before - 2856000);
  });

  it('lieu : ni transit ni inconnu ; commande qui n’a pas livré ce produit : refusé', async () => {
    const { productId } = await received();
    const other = await received();
    const transit = await prisma.location.findFirstOrThrow({
      where: { type: 'TRANSIT' },
    });
    // Du stock au transit (marchandise en route) : seule la garde refuse.
    await prisma.stock.create({
      data: { productId, locationId: transit.id, quantity: '5' },
    });
    await sendBack(productId, '1', { locationId: transit.id }).expect(422);
    await sendBack(productId, '1', { locationId: randomUUID() }).expect(422);
    await sendBack(productId, '1', {
      purchaseOrderId: other.orderId,
    }).expect(422);
    await sendBack(other.productId, '1', {
      purchaseOrderId: other.orderId,
    }).expect(201);
    expect(await stockOf(productId)).toBe('10.000');
  });

  it('même clé, autre lieu ou autre motif : 409', async () => {
    const { productId } = await received();
    const magasin = await prisma.location.findFirstOrThrow({
      where: { type: 'MAGASIN' },
    });
    const key = { clientMutationId: randomUUID() };
    await sendBack(productId, '1', key).expect(201);
    await sendBack(productId, '1', {
      ...key,
      locationId: magasin.id,
    }).expect(409);
    await sendBack(productId, '1', { ...key, reason: 'Autre motif' }).expect(
      409,
    );
  });
});
