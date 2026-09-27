import { writeFileSync } from 'fs';
import { join } from 'path';
import * as request from 'supertest';
import { RoleCode } from '../src/common/auth.decorators';
import { PrismaService } from '../src/prisma/prisma.service';
import { createE2eApp, createTestUser, E2eApp } from './helpers/e2e-app';

/// Bons PDF (P1 n°21c, spec §8quinquies) : bon de commande fournisseur et bon
/// de transfert. Chacun porte EXACTEMENT la garde du détail qu'il imprime.
///
/// `PDF_OUT=<dossier>` écrit les PDF produits, pour une relecture humaine.
describe('Bons PDF (e2e)', () => {
  let e2e: E2eApp;
  let prisma: PrismaService;
  let server: E2eApp['server'];

  const suffix = Date.now();
  const PASSWORD = 'MotDePasseTemp1!';
  const userIds: string[] = [];
  const tokens: Record<string, string> = {};
  const ids: Record<string, string> = {};
  let productId = '';
  let supplierId = '';
  let orderId = '';
  let transferId = '';

  const get = (token: string | null, url: string) => {
    const req = request(server).get(url);
    if (token) req.set('Authorization', `Bearer ${token}`);
    return req.buffer(true).parse((res, callback) => {
      const chunks: Buffer[] = [];
      res.on('data', (chunk: Buffer) => chunks.push(chunk));
      res.on('end', () => callback(null, Buffer.concat(chunks)));
    });
  };

  const keep = (name: string, pdf: Buffer) => {
    if (process.env.PDF_OUT)
      writeFileSync(join(process.env.PDF_OUT, name), pdf);
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
      const email = `e2e-doc-${key}-${suffix}@test.local`;
      const user = await createTestUser(prisma, {
        email,
        password: PASSWORD,
        roles: [role],
        fullName: `Membre ${key}`,
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
    const [magasin, depot] = await Promise.all([
      prisma.location.findFirstOrThrow({ where: { type: 'MAGASIN' } }),
      prisma.location.findFirstOrThrow({ where: { type: 'DEPOT' } }),
    ]);
    productId = (
      await prisma.product.create({
        data: {
          sku: `E2E-DOC-${suffix}`,
          barcode: `E2E-DOC-BC-${suffix}`,
          name: 'Câble 3G2,5 (bon)',
          unit: 'METRE',
        },
      })
    ).id;
    supplierId = (
      await prisma.supplier.create({
        data: {
          name: `Sonelec ${suffix}`,
          address: 'Zone industrielle, Alger',
          phone: '0550 11 22 33',
        },
      })
    ).id;
    orderId = (
      await prisma.purchaseOrder.create({
        data: {
          number: `BC-E2E-${suffix}`,
          supplierId,
          status: 'CONFIRMEE',
          createdById: ids.admin,
          totalHt: 1_200_000,
          totalTax: 228_000,
          totalTtc: 1_428_000,
          lines: {
            create: [
              {
                productId,
                orderedQuantity: '100.000',
                unitPriceHt: 12_000,
                taxRate: '19.00',
              },
            ],
          },
        },
      })
    ).id;
    transferId = (
      await prisma.transfer.create({
        data: {
          number: `TRF-E2E-${suffix}`,
          status: 'EN_TRANSIT',
          fromLocationId: depot.id,
          toLocationId: magasin.id,
          requestedById: ids.vendeur,
          preparedById: ids.magasinier,
          preparedAt: new Date(),
          shippedAt: new Date(),
          lines: {
            create: [
              {
                productId,
                requestedQuantity: '50.000',
                preparedQuantity: '48.500',
                shippedQuantity: '48.500',
              },
            ],
          },
        },
      })
    ).id;
  });

  afterAll(async () => {
    await prisma.transfer.deleteMany({ where: { id: transferId } });
    await prisma.purchaseOrder.deleteMany({ where: { id: orderId } });
    await prisma.supplier.deleteMany({ where: { id: supplierId } });
    await prisma.product.deleteMany({ where: { id: productId } });
    await prisma.auditLog.deleteMany({ where: { userId: { in: userIds } } });
    await prisma.user.deleteMany({ where: { id: { in: userIds } } });
    await e2e.app.close();
  });

  describe('bon de commande fournisseur', () => {
    it('ADMIN et MAGASINIER : un vrai PDF, nommé par la commande', async () => {
      for (const who of ['admin', 'magasinier']) {
        const res = await get(
          tokens[who],
          `/api/purchase-orders/${orderId}/pdf`,
        ).expect(200);
        const pdf = res.body as Buffer;
        expect(pdf.subarray(0, 5).toString()).toBe('%PDF-');
        expect(res.headers['content-disposition']).toContain(
          `BC-E2E-${suffix}.pdf`,
        );
        keep('bon-de-commande.pdf', pdf);
      }
    });

    /// Mêmes portes que le détail : le vendeur n'a AUCUN accès aux achats.
    it('mêmes refus que le détail de la commande', async () => {
      await get(tokens.vendeur, `/api/purchase-orders/${orderId}`).expect(403);
      await get(tokens.vendeur, `/api/purchase-orders/${orderId}/pdf`).expect(
        403,
      );
      await get(null, `/api/purchase-orders/${orderId}/pdf`).expect(401);
      await get(
        tokens.admin,
        '/api/purchase-orders/00000000-0000-4000-8000-000000000000/pdf',
      ).expect(404);
    });
  });

  describe('bon de transfert', () => {
    it('les trois rôles du flux : un vrai PDF', async () => {
      for (const who of ['admin', 'vendeur', 'magasinier']) {
        const detail = await get(tokens[who], `/api/transfers/${transferId}`);
        const res = await get(
          tokens[who],
          `/api/transfers/${transferId}/pdf`,
        ).expect(detail.status);
        expect((res.body as Buffer).subarray(0, 5).toString()).toBe('%PDF-');
        keep('bon-de-transfert.pdf', res.body as Buffer);
      }
      await get(null, `/api/transfers/${transferId}/pdf`).expect(401);
    });
  });
});
