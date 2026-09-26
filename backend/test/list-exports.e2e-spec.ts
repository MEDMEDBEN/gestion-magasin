import { randomUUID } from 'crypto';
import * as request from 'supertest';
import { RoleCode } from '../src/common/auth.decorators';
import { localDate } from '../src/common/document-number';
import { PrismaService } from '../src/prisma/prisma.service';
import { createE2eApp, createTestUser, E2eApp } from './helpers/e2e-app';

/// Exports des listes d'historique (P1 n°21 tranche B, spec §8quinquies).
///
/// Un export passe par le `findAll` de la liste : il en hérite les filtres ET le
/// cloisonnement. Ce qui est éprouvé ici, c'est qu'un fichier n'ouvre JAMAIS
/// plus que l'écran — même refus, mêmes lignes.
describe('Exports des listes (e2e)', () => {
  let e2e: E2eApp;
  let prisma: PrismaService;
  let server: E2eApp['server'];

  const suffix = Date.now();
  const PASSWORD = 'MotDePasseTemp1!';
  const DAY = 24 * 60 * 60 * 1000;
  const userIds: string[] = [];
  const productIds: string[] = [];
  const customerIds: string[] = [];
  const saleIds: string[] = [];
  const supplierIds: string[] = [];
  const orderIds: string[] = [];
  const receptionIds: string[] = [];
  const tokens: Record<string, string> = {};
  const ids: Record<string, string> = {};
  let magasinId: string;
  let counter = 0;

  const iso = (daysAgo: number) =>
    localDate(new Date(Date.now() - daysAgo * DAY));

  const as = (token: string) => ({
    get: (url: string) =>
      request(server).get(url).set('Authorization', `Bearer ${token}`),
  });

  /// Le fichier en texte (CSV), quel que soit le type annoncé.
  const csv = async (token: string, url: string, status = 200) => {
    const res = await request(server)
      .get(url)
      .set('Authorization', `Bearer ${token}`)
      .buffer(true)
      .parse((r, callback) => {
        const chunks: Buffer[] = [];
        r.on('data', (chunk: Buffer) => chunks.push(chunk));
        r.on('end', () => callback(null, Buffer.concat(chunks)));
      })
      .expect(status);
    return (res.body as Buffer).toString('utf8');
  };

  const sell = async (sellerKey: string, totalTtc: number, daysAgo = 1) => {
    const n = ++counter;
    const productId = productIds[0];
    const sale = await prisma.sale.create({
      data: {
        number: `E2E-LEX-V-${suffix}-${n}`,
        status: 'VALIDEE',
        userId: ids[sellerKey],
        customerId: customerIds[0],
        locationId: magasinId,
        totalHt: totalTtc,
        totalTax: 0,
        totalTtc,
        paidAmount: totalTtc,
        soldAt: new Date(Date.now() - daysAgo * DAY),
        lines: {
          create: [
            {
              productId,
              quantity: '1.000',
              unitPriceHt: totalTtc,
              taxRate: 0,
              discountAmount: 0,
              lineTotalHt: totalTtc,
              lineTaxAmount: 0,
              lineTotalTtc: totalTtc,
            },
          ],
        },
      },
    });
    saleIds.push(sale.id);
    return sale.number;
  };

  beforeAll(async () => {
    e2e = await createE2eApp();
    prisma = e2e.prisma;
    server = e2e.server;
    magasinId = (
      await prisma.location.findFirstOrThrow({ where: { type: 'MAGASIN' } })
    ).id;

    for (const [key, roles] of [
      ['admin', [RoleCode.ADMIN]],
      ['vendeurA', [RoleCode.VENDEUR]],
      ['vendeurB', [RoleCode.VENDEUR]],
      ['magasinier', [RoleCode.MAGASINIER]],
    ] as const) {
      const email = `e2e-lex-${key}-${suffix}@test.local`;
      const user = await createTestUser(prisma, {
        email,
        password: PASSWORD,
        roles: [...roles],
        fullName: `Membre ${key} ${suffix}`,
      });
      userIds.push(user.id);
      ids[key] = user.id;
      tokens[key] = (
        await request(server)
          .post('/api/auth/login')
          .send({ identifier: email, password: PASSWORD })
          .expect(200)
      ).body.accessToken;
    }

    const product = await prisma.product.create({
      data: {
        sku: `E2E-LEX-${suffix}`,
        barcode: `E2E-LEX-BC-${suffix}`,
        name: `Produit export ${suffix}`,
      },
    });
    productIds.push(product.id);
    const customer = await prisma.customer.create({
      data: { name: `=Client export ${suffix}` },
    });
    customerIds.push(customer.id);
  });

  afterAll(async () => {
    await prisma.reception.deleteMany({ where: { id: { in: receptionIds } } });
    await prisma.purchaseOrder.deleteMany({ where: { id: { in: orderIds } } });
    await prisma.supplier.deleteMany({ where: { id: { in: supplierIds } } });
    await prisma.stockMovement.deleteMany({
      where: { productId: { in: productIds } },
    });
    await prisma.stock.deleteMany({ where: { productId: { in: productIds } } });
    await prisma.saleLine.deleteMany({ where: { saleId: { in: saleIds } } });
    await prisma.sale.deleteMany({ where: { id: { in: saleIds } } });
    await prisma.customer.deleteMany({ where: { id: { in: customerIds } } });
    await prisma.product.deleteMany({ where: { id: { in: productIds } } });
    await prisma.auditLog.deleteMany({ where: { userId: { in: userIds } } });
    await prisma.user.deleteMany({ where: { id: { in: userIds } } });
    await e2e.app.close();
  });

  describe('ventes', () => {
    it('un vendeur n’exporte que SES ventes ; l’admin les voit toutes', async () => {
      const deA = await sell('vendeurA', 12_345, 500);
      const deB = await sell('vendeurB', 67_890, 500);
      const range = `from=${iso(500)}&to=${iso(500)}`;

      const pourA = await csv(
        tokens.vendeurA,
        `/api/sales/export?format=csv&${range}`,
      );
      expect(pourA).toContain(deA);
      expect(pourA).not.toContain(deB);
      expect(pourA).toContain('vos ventes uniquement');

      const pourAdmin = await csv(
        tokens.admin,
        `/api/sales/export?format=csv&${range}`,
      );
      expect(pourAdmin).toContain(deA);
      expect(pourAdmin).toContain(deB);
      // Noms joints, montants en dinars, nom de client neutralisé (formule).
      expect(pourAdmin).toContain(`Membre vendeurB ${suffix}`);
      expect(pourAdmin).toContain('678,90');
      expect(pourAdmin).toContain(`'=Client export ${suffix}`);
    });

    it('la période filtre la liste ET l’export, jours d’Alger inclus', async () => {
      const dedans = await sell('vendeurA', 1_000, 520);
      const dehors = await sell('vendeurA', 1_000, 530);
      const range = `from=${iso(521)}&to=${iso(520)}`;

      const liste = (
        await as(tokens.vendeurA).get(`/api/sales?${range}`).expect(200)
      ).body.data.map((s: { number: string }) => s.number);
      expect(liste).toContain(dedans);
      expect(liste).not.toContain(dehors);

      const fichier = await csv(
        tokens.vendeurA,
        `/api/sales/export?format=csv&${range}`,
      );
      expect(fichier).toContain(dedans);
      expect(fichier).not.toContain(dehors);

      await as(tokens.vendeurA)
        .get(`/api/sales?from=${iso(1)}&to=${iso(2)}`)
        .expect(400);
    });

    it('mêmes refus que la liste', async () => {
      await as(tokens.magasinier).get('/api/sales').expect(403);
      await as(tokens.magasinier)
        .get('/api/sales/export?format=csv')
        .expect(403);
      await request(server).get('/api/sales/export?format=csv').expect(401);
      await as(tokens.admin).get('/api/sales/export').expect(400);
    });

    it('PDF et Excel se téléchargent en pièce jointe', async () => {
      for (const format of ['pdf', 'xlsx']) {
        const res = await as(tokens.admin)
          .get(
            `/api/sales/export?format=${format}&from=${iso(500)}&to=${iso(500)}`,
          )
          .expect(200);
        expect(res.headers['content-disposition']).toBe(
          `attachment; filename="ventes_${iso(500)}_${iso(500)}.${format}"`,
        );
      }
    });
  });

  /// La propriété qui compte : pour CHAQUE rôle, l'export répond exactement ce
  /// que répond la liste. Un fichier n'ouvre jamais une porte fermée.
  describe('mêmes portes que la liste, pour chaque rôle', () => {
    const PAIRS = [
      ['/api/sales', '/api/sales/export'],
      ['/api/customers', '/api/customers/export'],
      ['/api/suppliers', '/api/suppliers/export'],
      ['/api/stock', '/api/stock/export'],
      ['/api/stock/movements', '/api/stock/movements/export'],
      ['/api/inventories', '/api/inventories/export'],
      ['/api/purchase-orders', '/api/purchase-orders/export'],
      ['/api/receptions', '/api/receptions/export'],
    ];

    it.each(PAIRS)('%s', async (list, exported) => {
      for (const who of ['admin', 'vendeurA', 'magasinier']) {
        const listStatus = (await as(tokens[who]).get(list)).status;
        const exportStatus = (
          await as(tokens[who]).get(`${exported}?format=csv`)
        ).status;
        expect({ who, status: exportStatus }).toEqual({
          who,
          status: listStatus,
        });
      }
      await request(server).get(`${exported}?format=csv`).expect(401);
      // Sans format : refusé, jamais un fichier par défaut.
      await as(tokens.admin).get(exported).expect(400);
    });

    it('le vendeur n’a AUCUN accès aux fournisseurs, fichier compris', async () => {
      await as(tokens.vendeurA)
        .get('/api/suppliers/export?format=csv')
        .expect(403);
      await as(tokens.vendeurA)
        .get('/api/suppliers/export?format=csv&debtOnly=true')
        .expect(403);
    });
  });

  describe('dettes clients', () => {
    it('`debtOnly` ne garde que les clients qui doivent', async () => {
      const debiteur = await prisma.customer.create({
        data: { name: `Débiteur export ${suffix}` },
      });
      const solde = await prisma.customer.create({
        data: { name: `Soldé export ${suffix}` },
      });
      customerIds.push(debiteur.id, solde.id);
      const vente = await prisma.sale.create({
        data: {
          number: `E2E-LEX-D-${suffix}`,
          status: 'VALIDEE',
          userId: ids.admin,
          customerId: debiteur.id,
          locationId: magasinId,
          totalHt: 50_000,
          totalTax: 0,
          totalTtc: 50_000,
          paidAmount: 20_000,
          dueDate: new Date(`${iso(-10)}T00:00:00Z`),
        },
      });
      saleIds.push(vente.id);

      const dettes = await csv(
        tokens.admin,
        `/api/customers/export?format=csv&debtOnly=true&q=${encodeURIComponent(`export ${suffix}`)}`,
      );
      expect(dettes).toContain('Dettes clients');
      expect(dettes).toContain(`Débiteur export ${suffix}`);
      expect(dettes).toContain('300,00');
      expect(dettes).not.toContain(`Soldé export ${suffix}`);

      const tous = await csv(
        tokens.admin,
        `/api/customers/export?format=csv&q=${encodeURIComponent(`export ${suffix}`)}`,
      );
      expect(tous).toContain(`Soldé export ${suffix}`);
    });
  });

  describe('stock', () => {
    /// Le stock du dépôt exige `stock.read.warehouse`. Les trois rôles l'ont
    /// aujourd'hui : on le retire du rôle en base (ce que l'admin peut faire),
    /// et l'export doit perdre le dépôt comme la liste.
    it('sans `stock.read.warehouse`, le dépôt disparaît du fichier', async () => {
      const depot = await prisma.location.findFirstOrThrow({
        where: { type: 'DEPOT' },
      });
      await prisma.stock.create({
        data: {
          productId: productIds[0],
          locationId: depot.id,
          quantity: '7.500',
        },
      });
      const url = `/api/stock/export?format=csv&productId=${productIds[0]}`;
      const avant = await csv(tokens.vendeurA, url);
      expect(avant).toContain(depot.name);
      expect(avant).toContain('7,500');

      const role = await prisma.role.findFirstOrThrow({
        where: { code: 'VENDEUR' },
      });
      const warehouse = await prisma.permission.findFirstOrThrow({
        where: { code: 'stock.read.warehouse' },
      });
      await prisma.role.update({
        where: { id: role.id },
        data: { permissions: { disconnect: { id: warehouse.id } } },
      });
      try {
        // Nouveau jeton : les droits de lecture viennent du jeton.
        const token = (
          await request(server)
            .post('/api/auth/login')
            .send({
              identifier: `e2e-lex-vendeurA-${suffix}@test.local`,
              password: PASSWORD,
            })
            .expect(200)
        ).body.accessToken;
        const apres = await csv(token, url);
        expect(apres).not.toContain(depot.name);
        expect(apres).not.toContain('7,500');
      } finally {
        // Restauré quoi qu'il arrive : la base e2e est partagée par les suites.
        await prisma.role.update({
          where: { id: role.id },
          data: { permissions: { connect: { id: warehouse.id } } },
        });
      }
    });

    it('les mouvements s’exportent avec le produit et l’emplacement nommés', async () => {
      const magasin = await prisma.location.findUniqueOrThrow({
        where: { id: magasinId },
      });
      await prisma.stockMovement.create({
        data: {
          productId: productIds[0],
          locationId: magasinId,
          quantity: '-2.250',
          type: 'PERTE_CASSE',
          operationType: 'MANUAL',
          userId: ids.magasinier,
        },
      });
      const fichier = await csv(
        tokens.magasinier,
        `/api/stock/movements/export?format=csv&productId=${productIds[0]}`,
      );
      expect(fichier).toContain(`Produit export ${suffix}`);
      expect(fichier).toContain(magasin.name);
      expect(fichier).toContain('-2,250');
      expect(fichier).toContain(`Membre magasinier ${suffix}`);
    });
  });

  /// Le détail d'une perte (constat libre, déclarant) relève de `stock.loss` :
  /// la liste le masque au vendeur, le fichier aussi.
  it('mouvements : le vendeur n’obtient pas le détail d’une perte', async () => {
    await prisma.stockMovement.create({
      data: {
        productId: productIds[0],
        locationId: magasinId,
        quantity: '-1.000',
        type: 'PERTE_CASSE',
        operationType: 'MANUAL',
        userId: ids.magasinier,
        comment: `Carton écrasé ${suffix}`,
      },
    });
    const url = `/api/stock/movements/export?format=csv&productId=${productIds[0]}`;
    const pourMagasinier = await csv(tokens.magasinier, url);
    expect(pourMagasinier).toContain(`Carton écrasé ${suffix}`);

    const pourVendeur = await csv(tokens.vendeurA, url);
    expect(pourVendeur).toContain('Perte / casse');
    expect(pourVendeur).not.toContain(`Carton écrasé ${suffix}`);
    expect(pourVendeur).not.toContain(`Membre magasinier ${suffix}`);
  });

  it('commandes et réceptions : la période filtre la liste ET le fichier', async () => {
    const supplier = await prisma.supplier.create({
      data: { name: `Fournisseur période ${suffix}` },
    });
    supplierIds.push(supplier.id);
    const commande = async (n: string, daysAgo: number) => {
      const order = await prisma.purchaseOrder.create({
        data: {
          number: `E2E-LEX-C-${suffix}-${n}`,
          supplierId: supplier.id,
          status: 'COMMANDEE',
          createdById: ids.admin,
          orderDate: new Date(Date.now() - daysAgo * DAY),
          totalHt: 1_000,
          totalTax: 0,
          totalTtc: 1_000,
        },
      });
      orderIds.push(order.id);
      return order.number;
    };
    const reception = async (n: string, daysAgo: number) => {
      const created = await prisma.reception.create({
        data: {
          number: `E2E-LEX-R-${suffix}-${n}`,
          supplierId: supplier.id,
          locationId: magasinId,
          userId: ids.admin,
          receivedAt: new Date(Date.now() - daysAgo * DAY),
          clientMutationId: randomUUID(),
        },
      });
      receptionIds.push(created.id);
      return created.number;
    };
    const cDedans = await commande('in', 540);
    const cDehors = await commande('out', 550);
    const rDedans = await reception('in', 540);
    const rDehors = await reception('out', 550);
    const range = `from=${iso(541)}&to=${iso(540)}&supplierId=${supplier.id}`;

    for (const [route, dedans, dehors] of [
      ['purchase-orders', cDedans, cDehors],
      ['receptions', rDedans, rDehors],
    ]) {
      const liste = (
        await as(tokens.magasinier).get(`/api/${route}?${range}`).expect(200)
      ).body.data.map((r: { number: string }) => r.number);
      expect(liste).toEqual([dedans]);

      const fichier = await csv(
        tokens.magasinier,
        `/api/${route}/export?format=csv&${range}`,
      );
      expect(fichier).toContain(dedans);
      expect(fichier).not.toContain(dehors);
    }
  });
});
