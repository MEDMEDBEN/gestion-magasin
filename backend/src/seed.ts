import 'dotenv/config';
import { PrismaPg } from '@prisma/adapter-pg';
import { PrismaClient } from './generated/prisma/client';
import { hashPassword } from './auth/password';
import { RoleCode } from './common/auth.decorators';
import {
  PERMISSION_DESCRIPTIONS,
  PERMISSIONS,
  ROLE_LABELS,
  ROLE_PERMISSIONS,
} from './common/permissions';

/// Seed IDEMPOTENT : chaque exécution converge vers le même état, sans doublon.
/// Ne crée QUE des données de référence — aucune donnée métier fictive.
const connectionString = process.env.DATABASE_URL;
if (!connectionString) {
  throw new Error('DATABASE_URL est absent — impossible de seeder.');
}
const prisma = new PrismaClient({
  adapter: new PrismaPg({ connectionString }),
});

async function seedPermissions(): Promise<void> {
  for (const code of Object.values(PERMISSIONS)) {
    await prisma.permission.upsert({
      where: { code },
      update: { description: PERMISSION_DESCRIPTIONS[code] },
      create: { code, description: PERMISSION_DESCRIPTIONS[code] },
    });
  }
  console.log(`  ✔ ${Object.values(PERMISSIONS).length} permissions`);
}

async function seedRoles(): Promise<void> {
  for (const code of Object.values(RoleCode)) {
    const permissionCodes = ROLE_PERMISSIONS[code];
    await prisma.role.upsert({
      where: { code },
      // `set` : le rôle reflète EXACTEMENT docs/permissions.md à chaque seed.
      update: {
        name: ROLE_LABELS[code],
        permissions: { set: permissionCodes.map((c) => ({ code: c })) },
      },
      create: {
        code,
        name: ROLE_LABELS[code],
        permissions: { connect: permissionCodes.map((c) => ({ code: c })) },
      },
    });
    console.log(`  ✔ rôle ${code} — ${permissionCodes.length} permissions`);
  }
}

async function seedLocations(): Promise<void> {
  const locations = [
    { code: 'MAGASIN', name: 'Magasin', type: 'MAGASIN' as const },
    { code: 'DEPOT', name: 'Dépôt', type: 'DEPOT' as const },
    { code: 'TRANSIT', name: 'En transit', type: 'TRANSIT' as const },
  ];
  for (const location of locations) {
    await prisma.location.upsert({
      where: { code: location.code },
      update: { name: location.name },
      create: location,
    });
  }
  console.log('  ✔ emplacements MAGASIN / DEPOT / TRANSIT');
}

/// Tarifs et taux de TVA de départ. Le seed tourne à CHAQUE démarrage du
/// conteneur : il crée ce qui manque et ne réécrit JAMAIS ce que l'admin a
/// réglé dans Paramètres (nom, taux, défaut, actif). Le défaut n'est posé que
/// s'il n'y en a encore aucun — jamais deux défauts.
async function seedPricingReferences(): Promise<void> {
  const tierDefault = await prisma.priceTier.count({
    where: { isDefault: true },
  });
  const tiers = [
    { code: 'DETAIL', name: 'Détail', isDefault: tierDefault === 0 },
    { code: 'GROS', name: 'Gros', isDefault: false },
  ];
  for (const tier of tiers) {
    await prisma.priceTier.upsert({
      where: { code: tier.code },
      update: {},
      create: tier,
    });
  }

  const taxDefault = await prisma.taxRate.count({ where: { isDefault: true } });
  const taxRates = [
    {
      code: 'TVA19',
      name: 'TVA 19 %',
      rate: '19.00',
      isDefault: taxDefault === 0,
    },
    { code: 'TVA0', name: 'Exonéré (0 %)', rate: '0.00', isDefault: false },
  ];
  for (const taxRate of taxRates) {
    await prisma.taxRate.upsert({
      where: { code: taxRate.code },
      update: {},
      create: taxRate,
    });
  }
  console.log(
    '  ✔ tarifs DETAIL/GROS + TVA 19 %/0 % (réglages existants gardés)',
  );
}

async function seedAdminUser(): Promise<void> {
  const email = process.env.SEED_ADMIN_EMAIL;
  const password = process.env.SEED_ADMIN_PASSWORD;

  if (!email || !password) {
    console.log(
      '  ⚠ SEED_ADMIN_EMAIL / SEED_ADMIN_PASSWORD absents — admin non créé (volontaire).',
    );
    return;
  }

  const existing = await prisma.user.findFirst({
    where: { email: { equals: email, mode: 'insensitive' } },
  });
  if (existing) {
    console.log(`  ✔ admin ${email} déjà présent — mot de passe inchangé`);
    return;
  }

  await prisma.user.create({
    data: {
      // Même normalisation que l'API : les emails sont stockés en minuscules.
      email: email.trim().toLowerCase(),
      fullName: process.env.SEED_ADMIN_NAME ?? 'Administrateur',
      passwordHash: await hashPassword(password),
      // Mot de passe TEMPORAIRE : changement imposé à la première connexion.
      mustChangePassword: true,
      roles: { connect: { code: RoleCode.ADMIN } },
    },
  });
  console.log(`  ✔ admin ${email} créé (mustChangePassword = true)`);
}

async function main(): Promise<void> {
  console.log('Seed — données de référence');
  await seedPermissions();
  await seedRoles();
  await seedLocations();
  await seedPricingReferences();
  await seedAdminUser();
  console.log('Seed terminé.');
}

main()
  .catch((error) => {
    console.error(error);
    process.exit(1);
  })
  .finally(() => void prisma.$disconnect());
