import { readFileSync } from 'fs';
import { join } from 'path';
import * as request from 'supertest';
import { RoleCode } from '../src/common/auth.decorators';
import { PrismaService } from '../src/prisma/prisma.service';
import { createE2eApp, createTestUser, E2eApp } from './helpers/e2e-app';

/// Lecture d'une facture (P2 n°24) : VRAIE reconnaissance de texte (Tesseract,
/// modèle français livré avec le serveur) sur une image de facture, puis
/// lignes proposées. Rien n'est écrit en base.
describe('Lecture de facture (e2e)', () => {
  let e2e: E2eApp;
  let prisma: PrismaService;
  let server: E2eApp['server'];

  const suffix = Date.now();
  const PASSWORD = 'MotDePasseTemp1!';
  const tokens: Record<string, string> = {};
  const userIds: string[] = [];
  let createdProductId: string | null = null;
  let restoreActive: { id: string; isActive: boolean } | null = null;
  let productId = '';
  const image = readFileSync(join(__dirname, 'fixtures', 'invoice.png'));

  const scan = (token: string, file: Buffer, name = 'facture.png') =>
    request(server)
      .post('/api/receptions/scan-invoice')
      .set('Authorization', `Bearer ${token}`)
      .attach('image', file, name);

  beforeAll(async () => {
    e2e = await createE2eApp();
    prisma = e2e.prisma;
    server = e2e.server;
    for (const [key, role] of [
      ['magasinier', RoleCode.MAGASINIER],
      ['vendeur', RoleCode.VENDEUR],
    ] as const) {
      const email = `e2e-ocr-${key}-${suffix}@test.local`;
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
    // La facture de test porte la référence « DIS-16A » (unique au catalogue).
    const existing = await prisma.product.findFirst({
      where: { sku: 'DIS-16A' },
    });
    if (existing) {
      productId = existing.id;
      restoreActive = { id: existing.id, isActive: existing.isActive };
      await prisma.product.update({
        where: { id: existing.id },
        data: { isActive: true },
      });
    } else {
      createdProductId = (
        await prisma.product.create({
          data: {
            sku: 'DIS-16A',
            barcode: `E2E-OCR-BC-${suffix}`,
            name: 'Disjoncteur 16A',
          },
        })
      ).id;
      productId = createdProductId;
    }
  }, 30_000);

  afterAll(async () => {
    if (createdProductId) {
      await prisma.product.delete({ where: { id: createdProductId } });
    }
    if (restoreActive) {
      await prisma.product.update({
        where: { id: restoreActive.id },
        data: { isActive: restoreActive.isActive },
      });
    }
    await prisma.user.deleteMany({ where: { id: { in: userIds } } });
    await e2e.app.close();
  });

  it('photo de facture → produit reconnu, quantité et prix proposés', async () => {
    const res = await scan(tokens.magasinier, image).expect(201);
    const line = (
      res.body.lines as {
        productId: string | null;
        quantity: string | null;
        unitPriceHt: number | null;
      }[]
    ).find((l) => l.productId === productId);
    expect(line).toMatchObject({ quantity: '10.000', unitPriceHt: 120000 });
    // Ligne sans produit connu : proposée, sans produit.
    expect(res.body.text).toContain('Gaine');
  }, 120_000);

  /// Audit sécurité n°24 : une image corrompue ne fait plus tomber le serveur ;
  /// une « bombe » (image immense dans un petit fichier) est refusée avant
  /// l'OCR.
  it('PNG corrompu : 422, et le serveur lit encore la facture suivante', async () => {
    const corrupt = Buffer.concat([
      image.subarray(0, 33),
      Buffer.alloc(500, 7),
    ]);
    await scan(tokens.magasinier, corrupt).expect(422);
    const bomb = Buffer.from(image);
    bomb.writeUInt32BE(20000, 16);
    bomb.writeUInt32BE(20000, 20);
    await scan(tokens.magasinier, bomb).expect(422);
    const again = await scan(tokens.magasinier, image).expect(201);
    expect(
      (again.body.lines as { productId: string | null }[]).some(
        (l) => l.productId === productId,
      ),
    ).toBe(true);
  }, 120_000);

  it('gardes : vendeur refusé ; fichier qui n’est pas une image : 422', async () => {
    await scan(tokens.vendeur, image).expect(403);
    await scan(tokens.magasinier, Buffer.from('pas une image'), 'x.png').expect(
      422,
    );
  });
});
