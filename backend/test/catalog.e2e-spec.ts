import { randomUUID } from 'crypto';
import * as request from 'supertest';
import { RoleCode } from '../src/common/auth.decorators';
import { gs1CheckDigit } from '../src/common/barcode/barcode';
import { CATALOG_SETTLE_MS } from '../src/products/catalog.service';
import { PrismaService } from '../src/prisma/prisma.service';
import {
  createE2eApp,
  createTestUser,
  E2eApp,
  failAuditInNextTransaction,
} from './helpers/e2e-app';

/// Feature P0 n°2 : produits, catégories, emplacements, codes-barres (règle 15),
/// matrice des 3 rôles (docs/permissions.md) et descente delta du catalogue.
describe('Catalogue (e2e)', () => {
  let e2e: E2eApp;
  let prisma: PrismaService;
  let server: E2eApp['server'];

  const suffix = Date.now();
  const PASSWORD = 'MotDePasseTemp1!';
  const userIds: string[] = [];
  const productIds: string[] = [];
  const categoryIds: string[] = [];
  const locationIds: string[] = [];
  let counter = 0;
  const tokens: Record<'admin' | 'vendeur' | 'magasinier', string> = {
    admin: '',
    vendeur: '',
    magasinier: '',
  };

  const as = (token: string) => ({
    get: (url: string) =>
      request(server).get(url).set('Authorization', `Bearer ${token}`),
    post: (url: string) =>
      request(server).post(url).set('Authorization', `Bearer ${token}`),
    patch: (url: string) =>
      request(server).patch(url).set('Authorization', `Bearer ${token}`),
  });
  const uid = (label: string) => `E2E-${label}-${suffix}-${++counter}`;

  /// EAN-13 fabricant valide et unique (préfixe 61 : jamais un code interne 20).
  const manufacturerEan = () => {
    const body = `61${String(suffix).slice(-7)}${String(++counter).padStart(3, '0')}`;
    return body + gs1CheckDigit(body);
  };

  const createProduct = async (extra: Record<string, unknown> = {}) => {
    const response = await as(tokens.admin)
      .post('/api/products')
      .send({
        sku: uid('SKU'),
        name: 'Disjoncteur 16A',
        unit: 'PIECE',
        ...extra,
      })
      .expect(201);
    productIds.push(response.body.id);
    return response.body;
  };

  beforeAll(async () => {
    e2e = await createE2eApp();
    prisma = e2e.prisma;
    server = e2e.server;
    for (const [key, role] of [
      ['admin', RoleCode.ADMIN],
      ['vendeur', RoleCode.VENDEUR],
      ['magasinier', RoleCode.MAGASINIER],
    ] as const) {
      const email = `e2e-catalog-${key}-${suffix}@test.local`;
      const user = await createTestUser(prisma, {
        email,
        password: PASSWORD,
        roles: [role],
      });
      userIds.push(user.id);
      const login = await request(server)
        .post('/api/auth/login')
        .send({ identifier: email, password: PASSWORD })
        .expect(200);
      tokens[key] = login.body.accessToken;
    }
  });

  afterAll(async () => {
    await prisma.auditLog.deleteMany({
      where: {
        OR: [{ entityId: { in: productIds } }, { userId: { in: userIds } }],
      },
    });
    await prisma.product.deleteMany({ where: { id: { in: productIds } } });
    await prisma.category.deleteMany({
      where: { parentId: { in: categoryIds } },
    });
    await prisma.category.deleteMany({ where: { id: { in: categoryIds } } });
    await prisma.location.deleteMany({ where: { id: { in: locationIds } } });
    await prisma.user.deleteMany({ where: { id: { in: userIds } } });
    await e2e.app.close();
  });

  afterEach(() => jest.restoreAllMocks());

  describe('codes-barres (règle 15)', () => {
    it('sans code, le serveur génère un EAN-13 interne 20… à clé valide', async () => {
      const product = await createProduct();
      expect(product.barcode).toMatch(/^20\d{11}$/);
      expect(Number(product.barcode[12])).toBe(
        gs1CheckDigit(product.barcode.slice(0, 12)),
      );
    });

    it('20 créations concurrentes → 20 codes distincts', async () => {
      const created = await Promise.all(
        Array.from({ length: 20 }, () => createProduct()),
      );
      expect(new Set(created.map((p) => p.barcode)).size).toBe(20);
    });

    it('un code interne déjà pris par une saisie manuelle est sauté', async () => {
      const [{ value }] = await prisma.$queryRaw<{ value: bigint }[]>`
        SELECT last_value + 1 AS value FROM product_internal_barcode_seq`;
      const body = `20${String(value).padStart(10, '0')}`;
      const squatted = body + gs1CheckDigit(body);
      await createProduct({ barcode: squatted });

      const generated = await createProduct();
      expect(generated.barcode).not.toBe(squatted);
      expect(generated.barcode).toMatch(/^20\d{11}$/);
    });

    it('code fabricant déjà attribué → 409 BARCODE_ALREADY_USED', async () => {
      const barcode = manufacturerEan();
      await createProduct({ barcode });
      const response = await as(tokens.admin)
        .post('/api/products')
        .send({ sku: uid('SKU'), name: 'Doublon', unit: 'PIECE', barcode })
        .expect(409);
      expect(response.body.code).toBe('BARCODE_ALREADY_USED');
    });

    it('GTIN à clé fausse (douchette qui lit mal) → 422', async () => {
      const good = manufacturerEan();
      const bad = good.slice(0, 12) + ((Number(good[12]) + 1) % 10);
      const response = await as(tokens.admin)
        .post('/api/products')
        .send({
          sku: uid('SKU'),
          name: 'Clé fausse',
          unit: 'PIECE',
          barcode: bad,
        })
        .expect(422);
      expect(response.body.code).toBe('VALIDATION_FAILED');
    });

    it('recherche par code-barres', async () => {
      const product = await createProduct({ barcode: manufacturerEan() });
      const found = await as(tokens.vendeur)
        .get(`/api/products/barcode/${product.barcode}`)
        .expect(200);
      expect(found.body.id).toBe(product.id);
      await as(tokens.vendeur).get('/api/products/barcode/0000').expect(404);
    });
  });

  describe('produits', () => {
    it('accepte l’id client, quantités en chaînes décimales, et trace la création', async () => {
      const id = randomUUID();
      const product = await createProduct({
        id,
        unit: 'METRE',
        minThreshold: '12.5',
      });
      expect(product.id).toBe(id);
      expect(product.minThreshold).toBe('12.500');
      expect(product.safetyStock).toBe('0.000');

      const audit = await prisma.auditLog.findMany({
        where: { entityType: 'Product', entityId: id },
      });
      expect(audit).toHaveLength(1);
      expect(audit[0].action).toBe('CREATE');
    });

    it('seuil négatif ou flottant exotique → 422', async () => {
      for (const minThreshold of ['-1', '1e3', '0.0001']) {
        await as(tokens.admin)
          .post('/api/products')
          .send({ sku: uid('SKU'), name: 'Seuil', unit: 'PIECE', minThreshold })
          .expect(422);
      }
    });

    it('référence déjà prise (sans la casse) → 409', async () => {
      const product = await createProduct();
      await as(tokens.admin)
        .post('/api/products')
        .send({
          sku: product.sku.toLowerCase(),
          name: 'Doublon',
          unit: 'PIECE',
        })
        .expect(409);
    });

    it('rattachement inexistant → 422, jamais une 500', async () => {
      await as(tokens.admin)
        .post('/api/products')
        .send({
          sku: uid('SKU'),
          name: 'Orphelin',
          unit: 'PIECE',
          categoryId: randomUUID(),
        })
        .expect(422);
    });

    it('PATCH : corrige le code-barres, retire la marque, trace avant/après', async () => {
      const product = await createProduct({ brand: 'Legrand' });
      const barcode = manufacturerEan();
      const response = await as(tokens.admin)
        .patch(`/api/products/${product.id}`)
        .send({ barcode, brand: null })
        .expect(200);
      expect(response.body.barcode).toBe(barcode);
      expect(response.body.brand).toBeNull();

      const [update] = await prisma.auditLog.findMany({
        where: {
          entityType: 'Product',
          entityId: product.id,
          action: 'UPDATE',
        },
      });
      expect(update.oldValue).toMatchObject({
        barcode: product.barcode,
        brand: 'Legrand',
      });
      expect(update.newValue).toMatchObject({ barcode, brand: null });
    });

    it('PATCH : `name: null` → 400', async () => {
      const product = await createProduct();
      await as(tokens.admin)
        .patch(`/api/products/${product.id}`)
        .send({ name: null })
        .expect(400);
    });

    it('audit en échec → produit NON modifié (atomicité)', async () => {
      const product = await createProduct();
      failAuditInNextTransaction(prisma);
      await as(tokens.admin)
        .patch(`/api/products/${product.id}`)
        .send({ name: 'Renommé' })
        .expect(500);
      const stored = await prisma.product.findUnique({
        where: { id: product.id },
      });
      expect(stored?.name).toBe(product.name);
    });

    it('liste paginée {data, meta}, recherche, inactifs masqués par défaut', async () => {
      const brand = uid('Marque');
      const active = await createProduct({ brand });
      const inactive = await createProduct({ brand });
      await as(tokens.admin)
        .patch(`/api/products/${inactive.id}`)
        .send({ isActive: false })
        .expect(200);

      const list = await as(tokens.magasinier)
        .get(`/api/products?q=${brand}`)
        .expect(200);
      expect(list.body.meta).toMatchObject({ page: 1, limit: 50, total: 1 });
      expect(list.body.data.map((p: { id: string }) => p.id)).toEqual([
        active.id,
      ]);

      const all = await as(tokens.magasinier)
        .get(`/api/products?q=${brand}&includeInactive=true`)
        .expect(200);
      expect(all.body.meta.total).toBe(2);

      await as(tokens.admin)
        .get('/api/products?sort=lastPurchasePriceHt:asc')
        .expect(400);
    });

    it('filtre catégorie : sous-catégories incluses', async () => {
      const root = await as(tokens.admin)
        .post('/api/categories')
        .send({ name: uid('Racine') })
        .expect(201);
      const child = await as(tokens.admin)
        .post('/api/categories')
        .send({ name: uid('Enfant'), parentId: root.body.id })
        .expect(201);
      categoryIds.push(root.body.id, child.body.id);
      const inChild = await createProduct({ categoryId: child.body.id });

      const list = await as(tokens.vendeur)
        .get(`/api/products?categoryId=${root.body.id}`)
        .expect(200);
      expect(list.body.data.map((p: { id: string }) => p.id)).toContain(
        inChild.id,
      );
    });
  });

  describe('matrice des rôles (docs/permissions.md)', () => {
    it('vendeur et magasinier consultent, ne créent ni ne modifient un produit', async () => {
      const product = await createProduct();
      for (const token of [tokens.vendeur, tokens.magasinier]) {
        await as(token).get(`/api/products/${product.id}`).expect(200);
        await as(token).get('/api/categories').expect(200);
        await as(token).get('/api/locations').expect(200);
        await as(token).get('/api/pricing/tax-rates').expect(200);
        await as(token).get('/api/catalog/changes?limit=1').expect(200);
        await as(token)
          .post('/api/products')
          .send({ sku: uid('X'), name: 'Interdit', unit: 'PIECE' })
          .expect(403);
        await as(token)
          .patch(`/api/products/${product.id}`)
          .send({ name: 'Interdit' })
          .expect(403);
        await as(token)
          .post('/api/categories')
          .send({ name: uid('Interdit') })
          .expect(403);
      }
    });

    it('emplacements : ADMIN et MAGASINIER gèrent, VENDEUR non', async () => {
      await as(tokens.vendeur)
        .post('/api/locations')
        .send({ zone: 'V' })
        .expect(403);
      const created = await as(tokens.magasinier)
        .post('/api/locations')
        .send({ code: uid('LOC').toUpperCase() })
        .expect(201);
      locationIds.push(created.body.id);
      await as(tokens.vendeur)
        .patch(`/api/locations/${created.body.id}`)
        .send({ isActive: false })
        .expect(403);
      await as(tokens.magasinier)
        .patch(`/api/locations/${created.body.id}`)
        .send({ isActive: false })
        .expect(200);
    });

    it('le prix reste 501 (feature Ventes / tarifs)', async () => {
      const product = await createProduct();
      await as(tokens.admin)
        .post(`/api/products/${product.id}/prices`)
        .send({ priceTierId: randomUUID(), priceHt: 100 })
        .expect(501);
    });
  });

  describe('catégories', () => {
    it('deux niveaux maximum, nom unique par parent sans la casse', async () => {
      const name = uid('Cables');
      const root = await as(tokens.admin)
        .post('/api/categories')
        .send({ name })
        .expect(201);
      categoryIds.push(root.body.id);
      await as(tokens.admin)
        .post('/api/categories')
        .send({ name: name.toLowerCase() })
        .expect(409);

      const child = await as(tokens.admin)
        .post('/api/categories')
        .send({ name: 'Souples', parentId: root.body.id })
        .expect(201);
      // Même nom sous un autre parent : autorisé.
      const other = await as(tokens.admin)
        .post('/api/categories')
        .send({ name: uid('Autre') })
        .expect(201);
      categoryIds.push(other.body.id);
      await as(tokens.admin)
        .post('/api/categories')
        .send({ name: 'Souples', parentId: other.body.id })
        .expect(201);

      // Petit-enfant refusé ; une catégorie qui a des enfants ne descend pas.
      await as(tokens.admin)
        .post('/api/categories')
        .send({ name: 'Trop profond', parentId: child.body.id })
        .expect(422);
      await as(tokens.admin)
        .patch(`/api/categories/${root.body.id}`)
        .send({ parentId: other.body.id })
        .expect(422);
    });

    it('deux créations concurrentes du même nom → une seule passe', async () => {
      const name = uid('Concurrente');
      const results = await Promise.all(
        [1, 2].map(() =>
          as(tokens.admin).post('/api/categories').send({ name }),
        ),
      );
      results
        .filter((r) => r.status === 201)
        .forEach((r) => categoryIds.push(r.body.id));
      expect(results.map((r) => r.status).sort()).toEqual([201, 409]);
    });
  });

  describe('emplacements (spec §5)', () => {
    it('code et nom dérivés de la structure, rattachés au dépôt', async () => {
      const zone = `Z${String(suffix).slice(-6)}`;
      const created = await as(tokens.admin)
        .post('/api/locations')
        .send({ zone, aisle: '02', shelf: '04', position: '03' })
        .expect(201);
      locationIds.push(created.body.id);
      expect(created.body.code).toBe(`${zone}-02-04-03`);
      expect(created.body.name).toBe(
        `Zone ${zone} · Rayon 02 · Étagère 04 · Position 03`,
      );
      expect(created.body.type).toBe('EMPLACEMENT');
      const depot = await prisma.location.findFirst({
        where: { type: 'DEPOT' },
      });
      expect(created.body.parentId).toBe(depot?.id);

      await as(tokens.admin)
        .post('/api/locations')
        .send({ zone, aisle: '02', shelf: '04', position: '03' })
        .expect(409);
    });

    it('MAGASIN/DEPOT/TRANSIT ne se créent ni ne se modifient', async () => {
      await as(tokens.admin)
        .post('/api/locations')
        .send({ code: uid('M').toUpperCase(), type: 'MAGASIN' })
        .expect(422);
      const magasin = await prisma.location.findFirst({
        where: { type: 'MAGASIN' },
      });
      await as(tokens.admin)
        .patch(`/api/locations/${magasin?.id}`)
        .send({ isActive: false })
        .expect(422);
    });

    it('un produit ne se range que sur un EMPLACEMENT actif', async () => {
      const depot = await prisma.location.findFirst({
        where: { type: 'DEPOT' },
      });
      await as(tokens.admin)
        .post('/api/products')
        .send({
          sku: uid('SKU'),
          name: 'Mal rangé',
          unit: 'PIECE',
          storageLocationId: depot?.id,
        })
        .expect(422);
    });
  });

  describe('descente delta du catalogue', () => {
    /// Fait « vieillir » une ligne au-delà du délai de stabilisation.
    const age = (id: string) =>
      prisma.product.update({
        where: { id },
        data: { updatedAt: new Date(Date.now() - CATALOG_SETTLE_MS - 1000) },
      });

    const pullAll = async (token: string, cursor?: string) => {
      const products: { id: string; isActive: boolean }[] = [];
      for (let guard = 0; guard < 1000; guard++) {
        const url = `/api/catalog/changes?limit=200${cursor ? `&cursor=${cursor}` : ''}`;
        const page = await as(token).get(url).expect(200);
        products.push(...page.body.products);
        cursor = page.body.cursor;
        if (!page.body.hasMore) break;
      }
      return { products, cursor: cursor! };
    };

    it('tout au départ, puis seulement les changements — inactifs compris', async () => {
      const first = await createProduct();
      await age(first.id);
      const initial = await pullAll(tokens.vendeur);
      expect(initial.products.map((p) => p.id)).toContain(first.id);

      // Rien de neuf : rien ne redescend.
      const again = await pullAll(tokens.vendeur, initial.cursor);
      expect(again.products.map((p) => p.id)).not.toContain(first.id);

      // Désactivé puis stabilisé : il redescend, marqué inactif.
      await prisma.product.update({
        where: { id: first.id },
        data: { isActive: false },
      });
      await age(first.id);
      const delta = await pullAll(tokens.vendeur, again.cursor);
      expect(delta.products.find((p) => p.id === first.id)?.isActive).toBe(
        false,
      );
    });

    it('une ligne trop récente attend le délai de stabilisation', async () => {
      const fresh = await createProduct();
      const { products } = await pullAll(tokens.vendeur);
      expect(products.map((p) => p.id)).not.toContain(fresh.id);
    });

    it('même instant pour plusieurs lignes : aucune perdue entre deux pages', async () => {
      const at = new Date(Date.now() - CATALOG_SETTLE_MS - 60_000);
      const batch = await Promise.all(
        Array.from({ length: 5 }, () => createProduct()),
      );
      await prisma.product.updateMany({
        where: { id: { in: batch.map((p) => p.id) } },
        data: { updatedAt: at },
      });
      const seen = new Set<string>();
      let cursor: string | undefined;
      for (let guard = 0; guard < 10_000; guard++) {
        const url = `/api/catalog/changes?limit=2${cursor ? `&cursor=${cursor}` : ''}`;
        const page = await as(tokens.vendeur).get(url).expect(200);
        page.body.products.forEach((p: { id: string }) => seen.add(p.id));
        cursor = page.body.cursor;
        if (!page.body.hasMore) break;
      }
      batch.forEach((p) => expect(seen).toContain(p.id));
    });

    it('curseur forgé → 400', async () => {
      await as(tokens.vendeur)
        .get('/api/catalog/changes?cursor=pas-un-curseur')
        .expect(400);
      const forged = Buffer.from(
        JSON.stringify({ products: ['x', "'; DROP"] }),
      ).toString('base64url');
      await as(tokens.vendeur)
        .get(`/api/catalog/changes?cursor=${forged}`)
        .expect(400);
    });
  });
});
