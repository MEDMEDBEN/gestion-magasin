import * as request from 'supertest';
import { randomUUID } from 'crypto';
import { RoleCode } from '../src/common/auth.decorators';
import { PrismaService } from '../src/prisma/prisma.service';
import { createE2eApp, createTestUser, E2eApp } from './helpers/e2e-app';

/// Notifications (P1 n°16, spec §18).
///
/// Éprouvé en priorité : personne ne lit ni ne modifie la boîte d'un collègue
/// (l'admin compris) ; l'alerte naît DANS la transaction de l'opération ; on
/// n'est jamais prévenu de sa propre action.
describe('Notifications (e2e)', () => {
  let e2e: E2eApp;
  let prisma: PrismaService;
  let server: E2eApp['server'];

  const suffix = Date.now();
  const PASSWORD = 'MotDePasseTemp1!';
  const userIds: string[] = [];
  const productIds: string[] = [];
  const ids: Record<string, string> = {};
  const tokens: Record<string, string> = {};
  let depotId: string;
  let productId: string;

  const as = (token: string) => ({
    get: (url: string) =>
      request(server).get(url).set('Authorization', `Bearer ${token}`),
    post: (url: string) =>
      request(server).post(url).set('Authorization', `Bearer ${token}`),
  });

  const inbox = async (who: string) =>
    (await as(tokens[who]).get('/api/notifications').expect(200)).body;

  /// Demande de transfert. Par défaut c'est le magasin (le vendeur) qui
  /// demande ; `who` permet de faire demander quelqu'un qui est LUI-MÊME
  /// destinataire de l'alerte (l'admin), seul cas où l'exclusion de l'auteur
  /// se vérifie vraiment.
  const demander = async (who = 'vendeur') =>
    (
      await as(tokens[who])
        .post('/api/transfers')
        .send({
          clientMutationId: randomUUID(),
          lines: [{ productId, quantity: '5' }],
        })
        .expect(201)
    ).body;

  beforeAll(async () => {
    e2e = await createE2eApp();
    prisma = e2e.prisma;
    server = e2e.server;
    depotId = (
      await prisma.location.findFirstOrThrow({ where: { type: 'DEPOT' } })
    ).id;
    const product = await prisma.product.create({
      data: {
        sku: `E2E-NOTIF-${suffix}`,
        barcode: `E2E-NOTIF-BC-${suffix}`,
        name: 'Câble notifications',
        stocks: { create: [{ locationId: depotId, quantity: '100' }] },
      },
    });
    productId = product.id;
    productIds.push(product.id);

    for (const [key, role] of [
      ['admin', RoleCode.ADMIN],
      ['vendeur', RoleCode.VENDEUR],
      ['magasinier', RoleCode.MAGASINIER],
      ['autreMagasinier', RoleCode.MAGASINIER],
    ] as const) {
      const email = `e2e-notif-${key}-${suffix}@test.local`;
      const user = await createTestUser(prisma, {
        email,
        password: PASSWORD,
        roles: [role],
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
  });

  afterAll(async () => {
    await prisma.notification.deleteMany({
      where: { userId: { in: userIds } },
    });
    await prisma.auditLog.deleteMany({ where: { userId: { in: userIds } } });
    await prisma.transferLine.deleteMany({
      where: { productId: { in: productIds } },
    });
    await prisma.transfer.deleteMany({
      where: { requestedById: { in: userIds } },
    });
    await prisma.stockMovement.deleteMany({
      where: { productId: { in: productIds } },
    });
    await prisma.stock.deleteMany({ where: { productId: { in: productIds } } });
    await prisma.product.deleteMany({ where: { id: { in: productIds } } });
    await prisma.user.deleteMany({ where: { id: { in: userIds } } });
    await e2e.app.close();
  });

  it('une demande au dépôt prévient les magasiniers, avec le lien vers l’opération', async () => {
    const avant = (await inbox('magasinier')).unread;
    const transfer = await demander();

    const apres = await inbox('magasinier');
    expect(apres.unread).toBe(avant + 1);
    expect(apres.data[0]).toMatchObject({
      type: 'NOUVELLE_DEMANDE_DEPOT',
      isRead: false,
      operationType: 'TRANSFER',
      operationId: transfer.id,
    });
    expect(apres.data[0].title).toContain(transfer.number);
  });

  /// L'admin est destinataire des alertes du dépôt : s'il demande lui-même,
  /// il ne doit pas recevoir son propre message — alors que ses collègues, si.
  it('l’auteur n’est PAS prévenu de sa propre demande, les autres oui', async () => {
    const sien = (await inbox('admin')).unread;
    const collegue = (await inbox('magasinier')).unread;

    await demander('admin');

    expect((await inbox('admin')).unread).toBe(sien);
    expect((await inbox('magasinier')).unread).toBe(collegue + 1);
  });

  it('la boîte d’un collègue est invisible, même pour l’admin', async () => {
    await demander();
    const magasinier = await inbox('magasinier');
    const cible = magasinier.data[0].id;

    // L'admin reçoit ses propres alertes, jamais celles d'un autre.
    const chezAdmin = await inbox('admin');
    expect(chezAdmin.data.map((n: { id: string }) => n.id)).not.toContain(
      cible,
    );

    // Et il ne peut pas la marquer lue à sa place.
    await as(tokens.admin).post(`/api/notifications/${cible}/read`).expect(201);
    const relue = await prisma.notification.findUniqueOrThrow({
      where: { id: cible },
    });
    expect(relue.isRead).toBe(false);
  });

  it('marquer lue est rejouable et rend le compteur restant', async () => {
    await demander();
    const boite = await inbox('magasinier');
    const cible = boite.data[0].id;

    const premier = (
      await as(tokens.magasinier)
        .post(`/api/notifications/${cible}/read`)
        .expect(201)
    ).body;
    expect(premier.unread).toBe(boite.unread - 1);

    // Rejouée : même état, le compteur ne descend pas deux fois.
    const second = (
      await as(tokens.magasinier)
        .post(`/api/notifications/${cible}/read`)
        .expect(201)
    ).body;
    expect(second.unread).toBe(premier.unread);
  });

  it('« tout marquer lu » ne vide que MA boîte', async () => {
    await demander();
    expect((await inbox('magasinier')).unread).toBeGreaterThan(0);
    const autre = (await inbox('autreMagasinier')).unread;
    expect(autre).toBeGreaterThan(0);

    const apres = (
      await as(tokens.magasinier)
        .post('/api/notifications/read-all')
        .expect(201)
    ).body;

    expect(apres.unread).toBe(0);
    expect((await inbox('autreMagasinier')).unread).toBe(autre);
  });

  it('`unreadOnly` ne rend que les non lues, le compteur reste global', async () => {
    await demander();
    await as(tokens.magasinier).post('/api/notifications/read-all').expect(201);
    await demander();

    const filtre = (
      await as(tokens.magasinier)
        .get('/api/notifications?unreadOnly=true')
        .expect(200)
    ).body;
    expect(filtre.data).toHaveLength(1);
    expect(filtre.data[0].isRead).toBe(false);
    expect(filtre.unread).toBe(1);

    const tout = await inbox('magasinier');
    expect(tout.data.length).toBeGreaterThan(1);
    expect(tout.unread).toBe(1);
  });

  /// Une saisie refusée n'écrit rien — ni document, ni alerte. (L'atomicité au
  /// sens de la règle 3, elle, tient du fait que l'écriture se fait avec le
  /// `tx` de l'opération : un échec APRÈS la notification annule les deux.)
  it('une préparation invalide n’écrit aucune alerte', async () => {
    const transfer = await demander();
    const avant = (await inbox('vendeur')).unread;

    // Quantité impossible : la préparation est refusée, donc aucune alerte.
    await as(tokens.magasinier)
      .post(`/api/transfers/${transfer.id}/prepare`)
      .send({ lines: [{ productId, preparedQuantity: '-1' }] })
      .expect(400);

    expect((await inbox('vendeur')).unread).toBe(avant);
  });

  it('sans token : refusé', async () => {
    await request(server).get('/api/notifications').expect(401);
  });

  /// Les alertes écrites par une notification portent un DESTINATAIRE : un
  /// mauvais ciblage ne lève rien, il ne se voit qu'en exploitation.
  const alertsOn = async (operationId: string, userId: string) =>
    prisma.notification.findMany({
      where: { operationId, userId },
      select: { type: true, title: true },
    });

  it('cycle du transfert : chaque étape prévient CEUX qui attendent', async () => {
    const transfer = await demander();

    // Préparée : le MAGASIN est prévenu, pas le préparateur.
    await as(tokens.magasinier)
      .post(`/api/transfers/${transfer.id}/prepare`)
      .send({ lines: [{ productId, preparedQuantity: '5' }] })
      .expect(200);
    expect(
      (await alertsOn(transfer.id, ids.vendeur)).map((n) => n.type),
    ).toContain('DEMANDE_PRETE');
    expect(
      (await alertsOn(transfer.id, ids.magasinier)).map((n) => n.type),
    ).not.toContain('DEMANDE_PRETE');

    // Expédiée : le magasin doit la réceptionner.
    await as(tokens.magasinier)
      .post(`/api/transfers/${transfer.id}/ship`)
      .expect(200);
    expect(
      (await alertsOn(transfer.id, ids.vendeur)).map((n) => n.type),
    ).toContain('TRANSFERT');

    // Reçue : le DÉPÔT apprend que sa marchandise est arrivée.
    await as(tokens.vendeur)
      .post(`/api/transfers/${transfer.id}/receive`)
      .send({ lines: [{ productId, receivedQuantity: '5' }] })
      .expect(200);
    expect(
      (await alertsOn(transfer.id, ids.magasinier)).map((n) => n.type),
    ).toContain('TRANSFERT_RECU');
    // Le réceptionnaire n'est pas prévenu de sa propre réception.
    expect(
      (await alertsOn(transfer.id, ids.vendeur)).map((n) => n.type),
    ).not.toContain('TRANSFERT_RECU');
  });

  it('demande ANNULÉE : le dépôt est prévenu, il préparait peut-être', async () => {
    const transfer = await demander();

    await as(tokens.vendeur)
      .post(`/api/transfers/${transfer.id}/cancel`)
      .send({ status: 'ANNULEE' })
      .expect(200);

    const chezDepot = await alertsOn(transfer.id, ids.magasinier);
    expect(chezDepot.map((n) => n.title).join(' ')).toContain('annulée');
  });

  it('un compte DÉSACTIVÉ ne reçoit plus rien', async () => {
    await prisma.user.update({
      where: { id: ids.autreMagasinier },
      data: { isActive: false },
    });
    const avant = await prisma.notification.count({
      where: { userId: ids.autreMagasinier },
    });

    await demander();

    expect(
      await prisma.notification.count({
        where: { userId: ids.autreMagasinier },
      }),
    ).toBe(avant);
    await prisma.user.update({
      where: { id: ids.autreMagasinier },
      data: { isActive: true },
    });
  });
});
