import { RoleCode } from '../src/common/auth.decorators';
import { NotificationType } from '../src/generated/prisma/client';
import { RemindersService } from '../src/notifications/reminders.service';
import { PrismaService } from '../src/prisma/prisma.service';
import { createE2eApp, createTestUser, E2eApp } from './helpers/e2e-app';

/// Rappels planifiés (P1 bis n°21j, spec §18) : 7 types qui n'étaient JAMAIS
/// émis. Éprouvé : chaque rappel part aux bons destinataires, pas quand rien
/// n'est dû, et un second balayage le même jour n'écrit rien (idempotence).
describe('Rappels planifiés (e2e)', () => {
  let e2e: E2eApp;
  let prisma: PrismaService;
  let reminders: RemindersService;

  const suffix = String(Date.now()).slice(-6);
  const DAY = 86_400_000;
  const day = (offset: number) => {
    // Jour local d'Alger à minuit UTC (forme des échéances enregistrées).
    const local = new Intl.DateTimeFormat('en-CA', {
      timeZone: 'Africa/Algiers',
    }).format(new Date(Date.now() + offset * DAY));
    return new Date(`${local}T00:00:00.000Z`);
  };
  const ids: Record<string, string> = {};

  const inbox = (userId: string, type: NotificationType, operationId: string) =>
    prisma.notification.count({ where: { userId, type, operationId } });

  beforeAll(async () => {
    e2e = await createE2eApp();
    prisma = e2e.prisma;
    reminders = e2e.app.get(RemindersService);
    for (const [key, role] of [
      ['admin', RoleCode.ADMIN],
      ['vendeur', RoleCode.VENDEUR],
      ['magasinier', RoleCode.MAGASINIER],
    ] as const) {
      ids[key] = (
        await createTestUser(prisma, {
          email: `e2e-rem-${key}-${suffix}@test.local`,
          password: 'MotDePasseTemp1!',
          roles: [role],
        })
      ).id;
    }
    const magasin = await prisma.location.findFirstOrThrow({
      where: { type: 'MAGASIN' },
    });

    // Fournisseur créancier (reprise de dette) : commande en retard de
    // livraison, et échéance de paiement aujourd'hui.
    const supplier = await prisma.supplier.create({
      data: { name: `Fournisseur REM ${suffix}`, openingBalance: 500000 },
    });
    ids.supplier = supplier.id;
    ids.latePo = (
      await prisma.purchaseOrder.create({
        data: {
          number: `BC-REM-${suffix}-1`,
          supplierId: supplier.id,
          createdById: ids.admin,
          status: 'CONFIRMEE',
          expectedDate: day(-2),
        },
      })
    ).id;
    ids.duePo = (
      await prisma.purchaseOrder.create({
        data: {
          number: `BC-REM-${suffix}-2`,
          supplierId: supplier.id,
          createdById: ids.admin,
          status: 'RECUE',
          dueDate: day(0),
        },
      })
    ).id;

    // Client à crédit : une vente due dans 2 jours, une autre en retard.
    const customer = await prisma.customer.create({
      data: { name: `Client REM ${suffix}`, creditLimit: 10_000_000 },
    });
    ids.customer = customer.id;
    const sale = (n: number, dueDate: Date) =>
      prisma.sale.create({
        data: {
          number: `TK-REM-${suffix}-${n}`,
          userId: ids.vendeur,
          locationId: magasin.id,
          customerId: customer.id,
          totalHt: 100000,
          totalTax: 19000,
          totalTtc: 119000,
          paidAmount: 0,
          dueDate,
        },
      });
    ids.soonSale = (await sale(1, day(2))).id;
    ids.lateSale = (await sale(2, day(-1))).id;

    // Client À JOUR grâce à un acompte général : rien à lui rappeler.
    const settled = await prisma.customer.create({
      data: { name: `Client soldé REM ${suffix}`, creditLimit: 10_000_000 },
    });
    ids.settled = settled.id;
    const settledSale = await prisma.sale.create({
      data: {
        number: `TK-REM-${suffix}-3`,
        userId: ids.vendeur,
        locationId: magasin.id,
        customerId: settled.id,
        totalHt: 100000,
        totalTax: 19000,
        totalTtc: 119000,
        paidAmount: 0,
        dueDate: day(-1),
      },
    });
    ids.settledSale = settledSale.id;
    await prisma.customerPayment.create({
      data: {
        customerId: settled.id,
        userId: ids.vendeur,
        amount: 119000,
        method: 'ESPECES',
      },
    });

    // Tâches du magasinier : une aujourd'hui, un comptage aujourd'hui, une
    // en retard.
    const task = (
      n: number,
      type: 'SAISIE' | 'COMPTAGE',
      at: Date,
      due: Date,
    ) =>
      prisma.planningTask.create({
        data: {
          title: `Tâche REM ${suffix}-${n}`,
          type,
          assignedToId: ids.magasinier,
          createdById: ids.admin,
          scheduledFor: at,
          dueDate: due,
        },
      });
    ids.todayTask = (await task(1, 'SAISIE', day(0), day(1))).id;
    ids.countTask = (await task(2, 'COMPTAGE', day(0), day(0))).id;
    ids.lateTask = (await task(3, 'SAISIE', day(-5), day(-2))).id;
  });

  afterAll(async () => {
    const userIds = [ids.admin, ids.vendeur, ids.magasinier];
    await prisma.notification.deleteMany({
      where: { userId: { in: userIds } },
    });
    await prisma.planningTask.deleteMany({
      where: { assignedToId: ids.magasinier },
    });
    await prisma.customerPayment.deleteMany({
      where: { customerId: { in: [ids.customer, ids.settled] } },
    });
    await prisma.sale.deleteMany({
      where: { customerId: { in: [ids.customer, ids.settled] } },
    });
    await prisma.customer.deleteMany({
      where: { id: { in: [ids.customer, ids.settled] } },
    });
    await prisma.purchaseOrder.deleteMany({
      where: { supplierId: ids.supplier },
    });
    await prisma.supplier.deleteMany({ where: { id: ids.supplier } });
    await prisma.user.deleteMany({ where: { id: { in: userIds } } });
    await e2e.app.close();
  });

  it('chaque rappel aux bons destinataires ; rien quand rien n’est dû', async () => {
    await reminders.sweep();

    // Fournisseur : retard de livraison (admin + magasinier) ; à payer (admin).
    expect(await inbox(ids.admin, 'RETARD_FOURNISSEUR', ids.latePo)).toBe(1);
    expect(await inbox(ids.magasinier, 'RETARD_FOURNISSEUR', ids.latePo)).toBe(
      1,
    );
    expect(await inbox(ids.admin, 'DETTE_FOURNISSEUR', ids.duePo)).toBe(1);
    expect(await inbox(ids.vendeur, 'DETTE_FOURNISSEUR', ids.duePo)).toBe(0);

    // Client : échéance proche et retard (admin + le vendeur de la vente).
    for (const user of [ids.admin, ids.vendeur]) {
      expect(await inbox(user, 'ECHEANCE_CLIENT', ids.soonSale)).toBe(1);
      expect(await inbox(user, 'DETTE_CLIENT_RETARD', ids.lateSale)).toBe(1);
    }
    expect(await inbox(ids.magasinier, 'ECHEANCE_CLIENT', ids.soonSale)).toBe(
      0,
    );
    // Soldé par un acompte général : aucun rappel.
    expect(
      await prisma.notification.count({
        where: { operationId: ids.settledSale },
      }),
    ).toBe(0);

    // Tâches : du jour et comptage à l'assigné ; retard à l'assigné + admin.
    expect(await inbox(ids.magasinier, 'TACHE_DU_JOUR', ids.todayTask)).toBe(1);
    expect(
      await inbox(ids.magasinier, 'INVENTAIRE_A_FAIRE', ids.countTask),
    ).toBe(1);
    expect(await inbox(ids.magasinier, 'TACHE_EN_RETARD', ids.lateTask)).toBe(
      1,
    );
    expect(await inbox(ids.admin, 'TACHE_EN_RETARD', ids.lateTask)).toBe(1);
  });

  it('second balayage le même jour : rien de plus (idempotent)', async () => {
    const before = await prisma.notification.count({
      where: { userId: { in: [ids.admin, ids.vendeur, ids.magasinier] } },
    });
    await reminders.sweep();
    expect(
      await prisma.notification.count({
        where: { userId: { in: [ids.admin, ids.vendeur, ids.magasinier] } },
      }),
    ).toBe(before);
  });

  it('tâche terminée, commande soldée : plus de rappel le lendemain', async () => {
    await prisma.planningTask.update({
      where: { id: ids.lateTask },
      data: { status: 'TERMINEE', completedAt: new Date() },
    });
    await prisma.purchaseOrder.update({
      where: { id: ids.latePo },
      data: { status: 'RECUE' },
    });
    const tomorrow = new Date(Date.now() + DAY);
    await reminders.sweep(tomorrow);
    expect(await inbox(ids.admin, 'TACHE_EN_RETARD', ids.lateTask)).toBe(1);
    expect(await inbox(ids.admin, 'RETARD_FOURNISSEUR', ids.latePo)).toBe(1);
    // La dette client, elle, est rappelée de nouveau le lendemain.
    expect(await inbox(ids.admin, 'DETTE_CLIENT_RETARD', ids.lateSale)).toBe(2);
  });
});
