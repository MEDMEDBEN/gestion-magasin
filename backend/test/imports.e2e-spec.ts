import { HttpStatus } from '@nestjs/common';
import * as request from 'supertest';
import { RoleCode } from '../src/common/auth.decorators';
import { BusinessException } from '../src/common/business.exception';
import { ErrorCode } from '../src/common/error-codes';
import { PrismaService } from '../src/prisma/prisma.service';
import { ProductsService } from '../src/products/products.service';
import { createE2eApp, createTestUser, E2eApp } from './helpers/e2e-app';

/// Import Excel/CSV (P1 n°21c partie 2, spec §8quinquies).
///
/// Éprouvé : la vérification à blanc n'écrit RIEN et liste TOUTES les erreurs
/// avec leur ligne ; l'application est TOUT OU RIEN (règle 3) ; le stock
/// initial passe par le journal (règle 2) ; les montants arrivent en centimes
/// entiers (règle 4) ; un fichier renvoyé ne double rien ; ADMIN seul.
describe('Import Excel/CSV (e2e)', () => {
  let e2e: E2eApp;
  let prisma: PrismaService;
  let server: E2eApp['server'];

  const suffix = String(Date.now()).slice(-8);
  const PASSWORD = 'MotDePasseTemp1!';
  const userIds: string[] = [];
  const tokens: Record<string, string> = {};
  let detailName = '';
  let grosName = '';

  const sku = (n: number) => `IMP${suffix}-${n}`;

  /// Envoi multipart d'un fichier (CSV en texte).
  const upload = (
    token: string | null,
    kind: string,
    content: string | Buffer,
    dryRun: boolean,
    name = 'import.csv',
  ) => {
    const req = request(server).post(`/api/imports/${kind}?dryRun=${dryRun}`);
    if (token) req.set('Authorization', `Bearer ${token}`);
    return req.attach(
      'file',
      typeof content === 'string' ? Buffer.from(content, 'utf8') : content,
      name,
    );
  };

  const csv = (header: string[], ...rows: string[][]) =>
    [header, ...rows].map((r) => r.join(';')).join('\n');

  beforeAll(async () => {
    e2e = await createE2eApp();
    prisma = e2e.prisma;
    server = e2e.server;
    detailName = (
      await prisma.priceTier.findUniqueOrThrow({ where: { code: 'DETAIL' } })
    ).name;
    grosName = (
      await prisma.priceTier.findUniqueOrThrow({ where: { code: 'GROS' } })
    ).name;
    for (const [key, role] of [
      ['admin', RoleCode.ADMIN],
      ['vendeur', RoleCode.VENDEUR],
      ['magasinier', RoleCode.MAGASINIER],
    ] as const) {
      const email = `e2e-imp-${key}-${suffix}@test.local`;
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
    const products = await prisma.product.findMany({
      where: { sku: { startsWith: `IMP${suffix}` } },
      select: { id: true },
    });
    const ids = products.map((p) => p.id);
    await prisma.stockMovement.deleteMany({
      where: { productId: { in: ids } },
    });
    await prisma.stock.deleteMany({ where: { productId: { in: ids } } });
    await prisma.productPrice.deleteMany({ where: { productId: { in: ids } } });
    await prisma.product.deleteMany({ where: { id: { in: ids } } });
    await prisma.customer.deleteMany({
      where: { name: { contains: `IMP${suffix}` } },
    });
    await prisma.supplier.deleteMany({
      where: { name: { contains: `IMP${suffix}` } },
    });
    await prisma.auditLog.deleteMany({ where: { userId: { in: userIds } } });
    await prisma.user.deleteMany({ where: { id: { in: userIds } } });
    await e2e.app.close();
  });

  describe('produits', () => {
    const header = () => [
      'Référence',
      'Nom',
      'Unité',
      'TVA %',
      `Prix ${detailName} HT`,
      `Prix ${grosName} HT`,
      'Stock magasin',
      'Stock dépôt',
    ];

    /// À blanc : RIEN n'est écrit, et TOUTES les lignes fautives sont listées
    /// avec leur numéro de ligne dans le fichier.
    it('à blanc : toutes les erreurs, avec leur ligne, rien d’écrit', async () => {
      const file = csv(
        header(),
        [
          sku(1),
          'Câble import',
          'Mètre',
          '19',
          '145,00',
          '120,00',
          '12,5',
          '100',
        ],
        [sku(2), 'Produit mal saisi', 'Carton', '19', '10', '', '', ''],
        [sku(3), 'Prix illisible', 'Pièce', '19', 'dix dinars', '', '', ''],
        [sku(1), 'Doublon de référence', 'Pièce', '19', '10', '', '', ''],
      );
      const res = await upload(tokens.admin, 'products', file, true).expect(
        200,
      );
      expect(res.body).toMatchObject({ dryRun: true, total: 4, created: 0 });
      const byLine = Object.fromEntries(
        res.body.errors.map((e: { line: number; message: string }) => [
          e.line,
          e.message,
        ]),
      );
      expect(Object.keys(byLine).map(Number)).toEqual([3, 4, 5]);
      expect(byLine[3]).toContain('unité « Carton » inconnue');
      expect(byLine[4]).toContain('n’est pas un montant');
      expect(byLine[5]).toContain('en double');
      expect(
        await prisma.product.count({
          where: { sku: { startsWith: `IMP${suffix}` } },
        }),
      ).toBe(0);
    });

    it('appliqué avec des erreurs : refusé, RIEN n’est créé', async () => {
      const file = csv(
        header(),
        [sku(10), 'Bon produit', 'Pièce', '19', '10', '', '', ''],
        [sku(11), 'Mauvais', 'Carton', '19', '10', '', '', ''],
      );
      await upload(tokens.admin, 'products', file, false).expect(422);
      expect(await prisma.product.count({ where: { sku: sku(10) } })).toBe(0);
    });

    /// Code-barres à la clé fausse : repéré DÈS la vérification à blanc (même
    /// normalisation que la création unitaire), pas au milieu de l'import.
    it('code-barres invalide : signalé à blanc, avec sa ligne', async () => {
      const file = csv(
        [...header(), 'Code-barres'],
        [sku(20), 'Premier', 'Pièce', '19', '10', '', '5', '', ''],
        [
          sku(21),
          'Code faux',
          'Pièce',
          '19',
          '10',
          '',
          '',
          '',
          '2000000000016',
        ],
      );
      const res = await upload(tokens.admin, 'products', file, true).expect(
        200,
      );
      expect(res.body.errors).toEqual([
        { line: 3, message: expect.stringContaining('clé de contrôle') },
      ]);
    });

    /// Règle 3 : une ligne refusée PENDANT l'écriture annule tout le fichier,
    /// y compris le stock initial déjà journalisé des lignes précédentes.
    it('tout ou rien : une ligne refusée à l’écriture annule tout', async () => {
      const products = e2e.app.get(ProductsService);
      const real = products.createInTx.bind(products);
      let calls = 0;
      const spy = jest
        .spyOn(products, 'createInTx')
        .mockImplementation(async (...args) => {
          calls += 1;
          if (calls === 2) {
            throw new BusinessException(
              ErrorCode.CONFLICT,
              'refus simulé',
              HttpStatus.CONFLICT,
            );
          }
          return real(...args);
        });
      try {
        const file = csv(
          header(),
          [sku(22), 'Premier', 'Pièce', '19', '10', '', '5', ''],
          [sku(23), 'Second', 'Pièce', '19', '10', '', '', ''],
        );
        const res = await upload(tokens.admin, 'products', file, false).expect(
          409,
        );
        // Code et statut d'origine gardés, ligne nommée.
        expect(res.body.code).toBe(ErrorCode.CONFLICT);
        expect(res.body.message).toContain('Ligne 3');
        expect(res.body.message).toContain('rien n’a été créé');
      } finally {
        spy.mockRestore();
      }
      expect(await prisma.product.count({ where: { sku: sku(22) } })).toBe(0);
    });

    /// Deux imports simultanés du même fichier : le verrou les met en file,
    /// les doublons sont recontrôlés dessous — une fiche, un mouvement.
    it('deux imports simultanés : un seul passe, rien n’est doublé', async () => {
      const file = csv(header(), [
        sku(25),
        'Concurrent',
        'Pièce',
        '19',
        '10',
        '',
        '7',
        '',
      ]);
      const results = await Promise.all([
        upload(tokens.admin, 'products', file, false),
        upload(tokens.admin, 'products', file, false),
      ]);
      expect(results.map((r) => r.status).sort()).toEqual([200, 409]);
      const product = await prisma.product.findUniqueOrThrow({
        where: { sku: sku(25) },
      });
      expect(
        await prisma.stockMovement.count({ where: { productId: product.id } }),
      ).toBe(1);
    });

    /// Messages en français, nommant la COLONNE ; espaces de bord retirés à
    /// la lecture ; TVA « 19 % » reconnue ; colonne inconnue signalée.
    it('messages par colonne, valeurs nettoyées, colonne inconnue signalée', async () => {
      const file = csv(
        [...header(), 'Prix TTC'],
        [sku(26), 'X', 'Pièce', '19', '10', '', '', '', '12'],
        [
          `  ${sku(27)}  `,
          '  Nettoyé  ',
          'Pièce',
          '19 %',
          '10',
          '',
          '',
          '',
          '',
        ],
        [sku(28), 'Prix énorme', 'Pièce', '19', '99999999', '', '', '', ''],
      );
      const res = await upload(tokens.admin, 'products', file, true).expect(
        200,
      );
      expect(res.body.ignored).toEqual(['Prix TTC']);
      const byLine = Object.fromEntries(
        res.body.errors.map((e: { line: number; message: string }) => [
          e.line,
          e.message,
        ]),
      );
      expect(Object.keys(byLine).map(Number)).toEqual([2, 4]);
      expect(byLine[2]).toBe('Nom : trop court');
      expect(byLine[4]).toBe(`Prix ${detailName} HT : trop grand`);

      await upload(
        tokens.admin,
        'products',
        csv(header(), [
          `  ${sku(27)}  `,
          '  Nettoyé  ',
          'Pièce',
          '19 %',
          '10',
          '',
          '',
          '',
        ]),
        false,
      ).expect(200);
      const cleaned = await prisma.product.findUniqueOrThrow({
        where: { sku: sku(27) },
      });
      expect(cleaned.name).toBe('Nettoyé');
    });

    it('appliqué : fiches, prix par tarif, stock initial par le journal', async () => {
      const file = csv(
        header(),
        [
          sku(30),
          'Câble importé',
          'Mètre',
          '19',
          '1 725,50',
          '1500',
          '12,5',
          '100',
        ],
        [sku(31), 'Disjoncteur importé', 'Pièce', '', '850', '', '', ''],
      );
      const res = await upload(tokens.admin, 'products', file, false).expect(
        200,
      );
      expect(res.body).toMatchObject({
        dryRun: false,
        total: 2,
        created: 2,
        errors: [],
      });

      const cable = await prisma.product.findUniqueOrThrow({
        where: { sku: sku(30) },
        include: { prices: { include: { priceTier: true } }, stocks: true },
      });
      expect(cable.unit).toBe('METRE');
      // Règle 4 : « 1 725,50 » → 172 550 centimes, sans flottant.
      expect(
        Object.fromEntries(
          cable.prices.map((p) => [p.priceTier.code, p.priceHt]),
        ),
      ).toEqual({ DETAIL: 172550, GROS: 150000 });
      expect(cable.stocks.map((s) => s.quantity.toFixed(3)).sort()).toEqual([
        '100.000',
        '12.500',
      ]);
      // Règle 2 : le stock est NÉ d'un mouvement du journal.
      const movements = await prisma.stockMovement.findMany({
        where: { productId: cable.id },
      });
      expect(movements.map((m) => m.type)).toEqual([
        'AJUSTEMENT_INVENTAIRE',
        'AJUSTEMENT_INVENTAIRE',
      ]);
      // Code-barres interne généré, comme à la création unitaire (règle 15).
      expect(cable.barcode).toMatch(/^20\d{11}$/);
    });

    it('le même fichier renvoyé : rien n’est doublé', async () => {
      const file = csv(header(), [
        sku(40),
        'Unique',
        'Pièce',
        '19',
        '10',
        '',
        '',
        '',
      ]);
      await upload(tokens.admin, 'products', file, false).expect(200);
      const again = await upload(tokens.admin, 'products', file, false).expect(
        422,
      );
      expect(again.body.message).toContain('rien n’a été créé');
      expect(await prisma.product.count({ where: { sku: sku(40) } })).toBe(1);
    });

    /// Le modèle téléchargé (lignes de titre comprises) se réimporte tel quel :
    /// la ligne d'en-tête est CHERCHÉE.
    it('le modèle Excel téléchargé se relit tel quel', async () => {
      const template = await request(server)
        .get('/api/imports/products/template?format=xlsx')
        .set('Authorization', `Bearer ${tokens.admin}`)
        .buffer(true)
        .parse((r, callback) => {
          const chunks: Buffer[] = [];
          r.on('data', (chunk: Buffer) => chunks.push(chunk));
          r.on('end', () => callback(null, Buffer.concat(chunks)));
        })
        .expect(200);
      const res = await upload(
        tokens.admin,
        'products',
        template.body as Buffer,
        true,
        'modele.xlsx',
      ).expect(200);
      // La ligne d'exemple est lue ; sa référence existe peut-être déjà.
      expect(res.body.total).toBe(1);
    });
  });

  describe('clients et fournisseurs', () => {
    it('clients : plafond en centimes, doublon de nom refusé', async () => {
      const name = `Client IMP${suffix}`;
      const file = csv(
        ['Nom', 'Téléphone', 'Plafond de crédit'],
        [name, '0550 12 34 56', '50 000,00'],
      );
      await upload(tokens.admin, 'customers', file, false).expect(200);
      const customer = await prisma.customer.findFirstOrThrow({
        where: { name },
      });
      expect(customer.creditLimit).toBe(5_000_000);

      const again = await upload(tokens.admin, 'customers', file, true).expect(
        200,
      );
      expect(again.body.errors[0].message).toContain('existe déjà');
      // Même nom, autres accents, casse et espaces : toujours un doublon.
      const variant = csv(
        ['Nom'],
        [`  client   imp${suffix} `.replace('client', 'Clíent')],
      );
      const accents = await upload(
        tokens.admin,
        'customers',
        variant,
        true,
      ).expect(200);
      expect(accents.body.errors[0].message).toContain('existe déjà');
    });

    it('fournisseurs : reprise de dette en centimes', async () => {
      const name = `Fournisseur IMP${suffix}`;
      const file = csv(
        ['Nom', 'Contact', 'Reprise de dette'],
        [name, 'M. Rahmani', '12 500,75'],
      );
      await upload(tokens.admin, 'suppliers', file, false).expect(200);
      const supplier = await prisma.supplier.findFirstOrThrow({
        where: { name },
      });
      expect(supplier.openingBalance).toBe(1_250_075);
    });

    it('en-têtes absents : message qui dit quoi faire', async () => {
      const res = await upload(
        tokens.admin,
        'customers',
        'Foo;Bar\n1;2',
        true,
      ).expect(422);
      expect(res.body.message).toContain('« Nom »');
    });
  });

  describe('qui peut importer', () => {
    /// Saisie en masse : ADMIN seul — même le vendeur, qui crée des clients à
    /// l'unité, n'importe pas un fichier.
    it('ADMIN seul, fichier obligatoire et borné', async () => {
      const file = csv(['Nom'], [`X IMP${suffix}`]);
      for (const kind of ['products', 'customers', 'suppliers']) {
        await upload(tokens.vendeur, kind, file, true).expect(403);
        await upload(tokens.magasinier, kind, file, true).expect(403);
        await upload(null, kind, file, true).expect(401);
        await request(server)
          .get(`/api/imports/${kind}/template?format=csv`)
          .set('Authorization', `Bearer ${tokens.vendeur}`)
          .expect(403);
      }
      await request(server)
        .post('/api/imports/customers?dryRun=true')
        .set('Authorization', `Bearer ${tokens.admin}`)
        .expect(400);
      // Au-delà de 2 Mo : refusé AVANT lecture complète.
      await upload(
        tokens.admin,
        'customers',
        Buffer.alloc(3 * 1024 * 1024, 'a'),
        true,
      ).expect(413);
    });
  });
});
