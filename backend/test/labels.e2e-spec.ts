import * as labelsModule from '../src/products/labels';
import * as request from 'supertest';
import { RoleCode } from '../src/common/auth.decorators';
import { PrismaService } from '../src/prisma/prisma.service';
import { createE2eApp, createTestUser, E2eApp } from './helpers/e2e-app';

/// Étiquettes code-barres (P1 n°21b, spec §8ter).
///
/// Éprouvé : chacun des trois rôles imprime (il lit produits ET prix) ; sans
/// `price.read`, refusé ; un produit sans prix au tarif ou désactivé n'a pas
/// d'étiquette ; les pages suivent le support (24 par planche, 1 par rouleau).
describe('Étiquettes (e2e)', () => {
  let e2e: E2eApp;
  let prisma: PrismaService;
  let server: E2eApp['server'];

  const suffix = Date.now();
  const PASSWORD = 'MotDePasseTemp1!';
  const userIds: string[] = [];
  const productIds: string[] = [];
  const tokens: Record<string, string> = {};
  let detailId = '';
  let grosId = '';
  let tva19Id = '';
  let counter = 0;

  const product = async (
    opts: {
      detail?: number;
      gros?: number;
      isActive?: boolean;
      barcode?: string;
    } = {},
  ) => {
    const n = ++counter;
    const created = await prisma.product.create({
      data: {
        sku: `E2E-LBL-${suffix}-${n}`,
        // Code COURT : un code long est refusé (illisible sur l'étiquette).
        barcode: opts.barcode ?? `L${String(suffix).slice(-8)}${n}`,
        name: `Produit étiquette ${n}`,
        isActive: opts.isActive ?? true,
        taxRateId: tva19Id,
        prices: {
          create: [
            ...(opts.detail === undefined
              ? []
              : [{ priceTierId: detailId, priceHt: opts.detail }]),
            ...(opts.gros === undefined
              ? []
              : [{ priceTierId: grosId, priceHt: opts.gros }]),
          ],
        },
      },
    });
    productIds.push(created.id);
    return created.id;
  };

  const labels = (token: string, body: object) =>
    request(server)
      .post('/api/products/labels')
      .set('Authorization', `Bearer ${token}`)
      .buffer(true)
      .parse((res, callback) => {
        const chunks: Buffer[] = [];
        res.on('data', (chunk: Buffer) => chunks.push(chunk));
        res.on('end', () => callback(null, Buffer.concat(chunks)));
      })
      .send(body);

  const pages = (pdf: Buffer) =>
    (pdf.toString('latin1').match(/\/Type \/Page\b/g) ?? []).length;

  const json = (res: request.Response) =>
    JSON.parse((res.body as Buffer).toString('utf8')) as {
      code: string;
      message: string;
    };

  beforeAll(async () => {
    e2e = await createE2eApp();
    prisma = e2e.prisma;
    server = e2e.server;
    detailId = (
      await prisma.priceTier.findUniqueOrThrow({ where: { code: 'DETAIL' } })
    ).id;
    grosId = (
      await prisma.priceTier.findUniqueOrThrow({ where: { code: 'GROS' } })
    ).id;
    tva19Id = (await prisma.taxRate.findFirstOrThrow({ where: { rate: 19 } }))
      .id;
    for (const [key, role] of [
      ['admin', RoleCode.ADMIN],
      ['vendeur', RoleCode.VENDEUR],
      ['magasinier', RoleCode.MAGASINIER],
    ] as const) {
      const email = `e2e-lbl-${key}-${suffix}@test.local`;
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
    await prisma.product.deleteMany({ where: { id: { in: productIds } } });
    await prisma.auditLog.deleteMany({ where: { userId: { in: userIds } } });
    await prisma.user.deleteMany({ where: { id: { in: userIds } } });
    await e2e.app.close();
  });

  it('les trois rôles impriment : planche A4 de 24 par page', async () => {
    const p = await product({ detail: 145000 });
    for (const who of ['admin', 'vendeur', 'magasinier']) {
      const res = await labels(tokens[who], {
        format: 'A4',
        items: [{ productId: p, copies: 25 }],
      }).expect(200);
      expect(res.headers['content-type']).toContain('application/pdf');
      expect(pages(res.body as Buffer)).toBe(2);
    }
  });

  it('rouleau : une étiquette par page, copies comprises', async () => {
    const a = await product({ detail: 1000 });
    const b = await product({ detail: 2000 });
    const res = await labels(tokens.vendeur, {
      format: 'ROULEAU',
      items: [
        { productId: a, copies: 2 },
        { productId: b, copies: 1 },
      ],
    }).expect(200);
    expect(pages(res.body as Buffer)).toBe(3);
  });

  /// Une étiquette sans prix collée en rayon ferait vendre au hasard : refus
  /// qui NOMME le produit.
  it('sans prix au tarif demandé : refusé, en nommant le produit', async () => {
    const p = await product({ detail: 1000 });
    const res = await labels(tokens.vendeur, {
      format: 'A4',
      priceTierId: grosId,
      items: [{ productId: p, copies: 1 }],
    }).expect(422);
    expect(json(res).code).toBe('PRICE_NOT_DEFINED');
    expect(json(res).message).toContain(`Produit étiquette ${counter}`);
  });

  it('produit désactivé : pas d’étiquette, et il est nommé', async () => {
    const p = await product({ detail: 1000, isActive: false });
    const res = await labels(tokens.vendeur, {
      format: 'A4',
      items: [{ productId: p, copies: 1 }],
    }).expect(422);
    expect(json(res).message).toContain(`Produit étiquette ${counter}`);
  });

  /// Chemin d'argent : le prix IMPRIMÉ est celui du tarif demandé, TTC calculé
  /// comme en caisse. Le PDF est compressé : on lit ce qui part au rendu.
  it('prix imprimé : celui du tarif demandé, TTC', async () => {
    const p = await product({ detail: 145000, gros: 120000 });
    const spy = jest.spyOn(labelsModule, 'renderLabels');
    try {
      await labels(tokens.vendeur, {
        format: 'A4',
        items: [{ productId: p, copies: 1 }],
      }).expect(200);
      // Tarif par défaut (DÉTAIL) : 1 450,00 HT + 19 % = 1 725,50 TTC.
      expect(spy.mock.calls[0][0][0].priceTtc).toBe(172550);
      await labels(tokens.vendeur, {
        format: 'A4',
        priceTierId: grosId,
        items: [{ productId: p, copies: 1 }],
      }).expect(200);
      // GROS : 1 200,00 HT + 19 % = 1 428,00 TTC.
      expect(spy.mock.calls[1][0][0].priceTtc).toBe(142800);
    } finally {
      spy.mockRestore();
    }
  });

  it('code-barres trop long pour être lu : refusé, en nommant le produit', async () => {
    const p = await product({
      detail: 1000,
      barcode: `LONG-${suffix}-${'X'.repeat(30)}`,
    });
    const res = await labels(tokens.vendeur, {
      format: 'A4',
      items: [{ productId: p, copies: 1 }],
    }).expect(422);
    expect(json(res).message).toContain('trop long');
    expect(json(res).message).toContain(`Produit étiquette ${counter}`);
  });

  it('exactement 1 000 étiquettes : acceptées', async () => {
    const p = await product({ detail: 1000 });
    const res = await labels(tokens.vendeur, {
      format: 'A4',
      items: Array.from({ length: 10 }, () => ({ productId: p, copies: 100 })),
    }).expect(200);
    expect(pages(res.body as Buffer)).toBe(42);
  });

  it('bornes : copies, nombre total, format', async () => {
    const p = await product({ detail: 1000 });
    await labels(tokens.vendeur, {
      format: 'A4',
      items: [{ productId: p, copies: 101 }],
    }).expect(400);
    await labels(tokens.vendeur, {
      format: 'A4',
      items: Array.from({ length: 11 }, () => ({ productId: p, copies: 100 })),
    }).expect(400);
    await labels(tokens.vendeur, {
      format: 'LETTRE',
      items: [{ productId: p, copies: 1 }],
    }).expect(400);
  });

  /// Le prix est imprimé : sans `price.read`, pas d'étiquette. Les trois rôles
  /// ont ce droit aujourd'hui ; on le retire du rôle en base (ce que l'admin
  /// peut faire), la relecture des droits le voit tout de suite.
  it('sans `price.read` : refusé', async () => {
    const p = await product({ detail: 1000 });
    const role = await prisma.role.findFirstOrThrow({
      where: { code: 'MAGASINIER' },
    });
    const price = await prisma.permission.findFirstOrThrow({
      where: { code: 'price.read' },
    });
    await prisma.role.update({
      where: { id: role.id },
      data: { permissions: { disconnect: { id: price.id } } },
    });
    try {
      await labels(tokens.magasinier, {
        format: 'A4',
        items: [{ productId: p, copies: 1 }],
      }).expect(403);
    } finally {
      await prisma.role.update({
        where: { id: role.id },
        data: { permissions: { connect: { id: price.id } } },
      });
    }
    await request(server)
      .post('/api/products/labels')
      .send({ format: 'A4', items: [{ productId: p, copies: 1 }] })
      .expect(401);
  });
});
