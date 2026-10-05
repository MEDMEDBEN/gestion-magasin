import { ConfigService } from '@nestjs/config';
import { execSync } from 'child_process';
import { join } from 'path';
import * as request from 'supertest';
import { RoleCode } from '../src/common/auth.decorators';
import { PrismaService } from '../src/prisma/prisma.service';
import { storeIdentity } from '../src/settings/store-settings';
import { createE2eApp, createTestUser, E2eApp } from './helpers/e2e-app';

/// Paramètres (P1 bis n°21h) : tarifs, identité du magasin. La gestion des
/// taux de TVA est RETIRÉE (décision MEDMEDBEN 2026-10-05) : ses routes
/// n'existent plus (404).
///
/// Éprouvé : ADMIN seul (`price.manage` / `settings.manage`) ; un seul défaut,
/// le défaut ne se désactive pas ; codes uniques ; chaque écriture auditée ;
/// l'identité saisie est celle IMPRIMÉE, un champ vidé retombe sur
/// l'environnement.
describe('Paramètres (e2e)', () => {
  let e2e: E2eApp;
  let prisma: PrismaService;
  let server: E2eApp['server'];

  const suffix = String(Date.now()).slice(-6);
  const PASSWORD = 'MotDePasseTemp1!';
  const userIds: string[] = [];
  const tokens: Record<string, string> = {};
  let defaultTierId = '';
  let defaultTaxId = '';

  const as = (token: string) => ({
    get: (url: string) =>
      request(server).get(url).set('Authorization', `Bearer ${token}`),
    post: (url: string) =>
      request(server).post(url).set('Authorization', `Bearer ${token}`),
    patch: (url: string) =>
      request(server).patch(url).set('Authorization', `Bearer ${token}`),
  });

  beforeAll(async () => {
    e2e = await createE2eApp();
    prisma = e2e.prisma;
    server = e2e.server;
    defaultTierId = (
      await prisma.priceTier.findFirstOrThrow({ where: { isDefault: true } })
    ).id;
    defaultTaxId = (
      await prisma.taxRate.findFirstOrThrow({ where: { isDefault: true } })
    ).id;
    for (const [key, role] of [
      ['admin', RoleCode.ADMIN],
      ['vendeur', RoleCode.VENDEUR],
      ['magasinier', RoleCode.MAGASINIER],
    ] as const) {
      const email = `e2e-set-${key}-${suffix}@test.local`;
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
    // Les défauts d'origine reviennent : les autres suites en dépendent.
    await prisma.priceTier.updateMany({ data: { isDefault: false } });
    await prisma.priceTier.update({
      where: { id: defaultTierId },
      data: { isDefault: true, isActive: true },
    });
    await prisma.taxRate.updateMany({ data: { isDefault: false } });
    await prisma.taxRate.update({
      where: { id: defaultTaxId },
      data: { isDefault: true, isActive: true },
    });
    await prisma.priceTier.deleteMany({
      where: { code: { endsWith: `_${suffix}` } },
    });
    await prisma.taxRate.deleteMany({
      where: { code: { endsWith: `_${suffix}` } },
    });
    await prisma.storeSettings.deleteMany();
    await prisma.auditLog.deleteMany({ where: { userId: { in: userIds } } });
    await prisma.user.deleteMany({ where: { id: { in: userIds } } });
    await e2e.app.close();
  });

  describe('tarifs', () => {
    it('créer, doublon refusé, renommer, désigner par défaut, désactiver', async () => {
      const code = `REV_${suffix}`;
      const created = (
        await as(tokens.admin)
          .post('/api/pricing/tiers')
          .send({ code: code.toLowerCase(), name: 'Revendeur' })
          .expect(201)
      ).body;
      expect(created).toMatchObject({ code, isDefault: false, isActive: true });
      await as(tokens.admin)
        .post('/api/pricing/tiers')
        .send({ code, name: 'Doublon' })
        .expect(409);

      await as(tokens.admin)
        .patch(`/api/pricing/tiers/${created.id}`)
        .send({ name: 'Revendeurs agréés', isDefault: true })
        .expect(200);
      // UN seul défaut : l'ancien ne l'est plus.
      const defaults = await prisma.priceTier.findMany({
        where: { isDefault: true },
      });
      expect(defaults.map((t) => t.id)).toEqual([created.id]);

      // Le défaut ne se désactive pas ; on en désigne d'abord un autre.
      await as(tokens.admin)
        .patch(`/api/pricing/tiers/${created.id}`)
        .send({ isActive: false })
        .expect(409);
      await as(tokens.admin)
        .patch(`/api/pricing/tiers/${defaultTierId}`)
        .send({ isDefault: true })
        .expect(200);
      await as(tokens.admin)
        .patch(`/api/pricing/tiers/${created.id}`)
        .send({ isActive: false })
        .expect(200);

      // Inactif : absent de la liste courante, présent pour Paramètres.
      const active = (await as(tokens.vendeur).get('/api/pricing/tiers'))
        .body as { id: string }[];
      expect(active.map((t) => t.id)).not.toContain(created.id);
      const all = (
        await as(tokens.admin).get('/api/pricing/tiers?includeInactive=true')
      ).body as { id: string; isActive: boolean }[];
      expect(all.find((t) => t.id === created.id)?.isActive).toBe(false);

      const audit = await prisma.auditLog.findMany({
        where: { entityType: 'PriceTier', entityId: created.id },
      });
      expect(audit.map((a) => a.action).sort()).toEqual([
        'CREATE',
        'UPDATE',
        'UPDATE',
      ]);
    });

    it('`isDefault: false` n’existe pas : on désigne un autre défaut', async () => {
      await as(tokens.admin)
        .patch(`/api/pricing/tiers/${defaultTierId}`)
        .send({ isDefault: false })
        .expect(400);
    });
  });

  describe('taux de TVA (retirés)', () => {
    it('POST / PATCH / GET /api/pricing/tax-rates → 404, aucun taux touché', async () => {
      const before = await prisma.taxRate.findMany({
        orderBy: { code: 'asc' },
      });
      await as(tokens.admin)
        .post('/api/pricing/tax-rates')
        .send({ code: `TVA9_${suffix}`, name: 'TVA 9 %', rate: '9' })
        .expect(404);
      await as(tokens.admin)
        .patch(`/api/pricing/tax-rates/${defaultTaxId}`)
        .send({ rate: '9.5' })
        .expect(404);
      await as(tokens.admin).get('/api/pricing/tax-rates').expect(404);
      expect(
        await prisma.taxRate.findMany({ orderBy: { code: 'asc' } }),
      ).toEqual(before);
    });
  });

  describe('identité du magasin', () => {
    it('saisie par l’admin, IMPRIMÉE sur les documents ; vidée : retour env', async () => {
      await as(tokens.admin)
        .patch('/api/settings/store')
        .send({ name: '  Électricité El Nour  ', nif: '000016001234567' })
        .expect(200);
      const store = (await as(tokens.admin).get('/api/settings/store')).body;
      expect(store).toMatchObject({
        name: 'Électricité El Nour',
        nif: '000016001234567',
      });
      // IMPRIMÉE : ticket, facture, devis et bons lisent `storeIdentity`.
      // Une facture exige NIF ET RC : sans RC (ni env), refusée…
      const config = e2e.app.get(ConfigService);
      // L'env de test n'a pas de RC : sinon cette preuve n'aurait pas de sens.
      expect(config.get<string>('STORE_RC') ?? '').toBe('');
      await expect(storeIdentity(prisma, config, true)).rejects.toThrow(
        'Paramètres',
      );
      // … RC saisi dans Paramètres : acceptée, avec les deux mentions.
      await as(tokens.admin)
        .patch('/api/settings/store')
        .send({ rc: '31/00-0123456B21' })
        .expect(200);
      const printed = await storeIdentity(prisma, config, true);
      expect(printed.name).toBe('Électricité El Nour');
      expect(printed.legal).toEqual(
        expect.arrayContaining([
          'NIF : 000016001234567',
          'RC : 31/00-0123456B21',
        ]),
      );

      const audit = await prisma.auditLog.findFirstOrThrow({
        where: { entityType: 'StoreSettings' },
        orderBy: { createdAt: 'desc' },
      });
      expect(audit.newValue).toMatchObject({ name: 'Électricité El Nour' });

      // Vidé : la valeur de l'environnement revient (déploiement existant).
      const cleared = (
        await as(tokens.admin)
          .patch('/api/settings/store')
          .send({ name: '' })
          .expect(200)
      ).body;
      expect(cleared.name).toBe(process.env.STORE_NAME?.trim() || null);
    });
  });

  describe('robustesse (audits 21h)', () => {
    it('`null` dans une modification : 400, jamais une 500', async () => {
      for (const body of [{ name: null }, { isActive: null }]) {
        await as(tokens.admin)
          .patch(`/api/pricing/tiers/${defaultTierId}`)
          .send(body)
          .expect(400);
      }
    });

    it('identité : arabe, emoji, retour à la ligne refusés (illisibles au PDF)', async () => {
      for (const name of ['كهرباء النور', 'Nour ⚡', 'Ligne 1\nNIF : faux']) {
        await as(tokens.admin)
          .patch('/api/settings/store')
          .send({ name })
          .expect(400);
      }
    });

    it('rien de changé : pas de ligne d’audit', async () => {
      const count = () =>
        prisma.auditLog.count({
          where: { entityId: defaultTierId, entityType: 'PriceTier' },
        });
      const before = await count();
      await as(tokens.admin)
        .patch(`/api/pricing/tiers/${defaultTierId}`)
        .send({})
        .expect(200);
      expect(await count()).toBe(before);
    });

    /// Le seed tourne à CHAQUE démarrage du conteneur : il ne doit jamais
    /// défaire un réglage de l'admin (il réécrivait noms, taux et défauts).
    it('seed relancé : les réglages de l’admin tiennent, un seul défaut', async () => {
      const mine = (
        await as(tokens.admin)
          .post('/api/pricing/tiers')
          .send({ code: `SEED_${suffix}`, name: 'Défaut admin' })
          .expect(201)
      ).body;
      await as(tokens.admin)
        .patch(`/api/pricing/tiers/${mine.id}`)
        .send({ isDefault: true })
        .expect(200);
      const tva19 = await prisma.taxRate.findUniqueOrThrow({
        where: { code: 'TVA19' },
      });
      // Plus de route pour les taux (TVA retirée) : renommé en base, le seed
      // ne doit pas l'écraser pour autant.
      await prisma.taxRate.update({
        where: { id: tva19.id },
        data: { name: `TVA dix-neuf ${suffix}` },
      });
      try {
        execSync('node -r ts-node/register/transpile-only src/seed.ts', {
          cwd: join(__dirname, '..'),
          env: process.env,
          stdio: 'pipe',
        });
        const defaults = await prisma.priceTier.findMany({
          where: { isDefault: true },
        });
        expect(defaults.map((t) => t.id)).toEqual([mine.id]);
        expect(
          (await prisma.taxRate.findUniqueOrThrow({ where: { code: 'TVA19' } }))
            .name,
        ).toBe(`TVA dix-neuf ${suffix}`);
      } finally {
        await prisma.taxRate.update({
          where: { id: tva19.id },
          data: { name: tva19.name },
        });
      }
    }, 60_000);
  });

  describe('qui peut régler', () => {
    it('ADMIN seul, lecture de l’identité comprise', async () => {
      for (const token of [tokens.vendeur, tokens.magasinier]) {
        await as(token)
          .post('/api/pricing/tiers')
          .send({ code: `X_${suffix}`, name: 'Refusé' })
          .expect(403);
        await as(token)
          .patch(`/api/pricing/tiers/${defaultTierId}`)
          .send({ name: 'Refusé' })
          .expect(403);
        await as(token).get('/api/settings/store').expect(403);
        await as(token)
          .patch('/api/settings/store')
          .send({ name: 'Refusé' })
          .expect(403);
      }
    });
  });
});
