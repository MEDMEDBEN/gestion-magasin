import { HttpStatus } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { BusinessException } from '../common/business.exception';
import { ErrorCode } from '../common/error-codes';
import { Prisma } from '../generated/prisma/client';
import { PrismaService } from '../prisma/prisma.service';

type Db = Prisma.TransactionClient | PrismaService;

/// Identité du magasin (P1 bis n°21h) : saisie par l'ADMIN dans Paramètres
/// (table `StoreSettings`, une ligne), chaque champ vide retombant sur la
/// variable d'environnement STORE_* — un déploiement existant ne change pas.
export const STORE_FIELDS = [
  'name',
  'address',
  'phone',
  'nif',
  'rc',
  'nis',
  'ai',
] as const;
export type StoreField = (typeof STORE_FIELDS)[number];
export type StoreSettingsValues = Record<StoreField, string | null>;

/// Valeurs EFFECTIVES (base, sinon environnement) : ce que les documents
/// impriment et ce que l'écran Paramètres affiche.
export async function storeSettings(
  db: Db,
  config: ConfigService,
): Promise<StoreSettingsValues> {
  const row = await db.storeSettings.findUnique({ where: { id: 1 } });
  const values = {} as StoreSettingsValues;
  for (const field of STORE_FIELDS) {
    values[field] =
      row?.[field]?.trim() ||
      config.get<string>(`STORE_${field.toUpperCase()}`)?.trim() ||
      null;
  }
  return values;
}

export interface StoreIdentity {
  name: string;
  address?: string;
  phone?: string;
  /// Mentions légales (NIF, RC, NIS, AI) déjà mises en forme, une par entrée.
  legal: string[];
}

/// Identité imprimée en tête des documents. `requireLegal` : une facture exige
/// ses mentions légales ; un ticket, un devis ou un bon reste imprimable sans.
export async function storeIdentity(
  db: Db,
  config: ConfigService,
  requireLegal: boolean,
): Promise<StoreIdentity> {
  const s = await storeSettings(db, config);
  if (requireLegal && !(s.nif && s.rc)) {
    throw new BusinessException(
      ErrorCode.STORE_IDENTITY_MISSING,
      'Mentions légales du magasin absentes (NIF, RC) : facture non imprimable — ' +
        'à renseigner dans Paramètres',
      HttpStatus.UNPROCESSABLE_ENTITY,
    );
  }
  const legal = (['nif', 'rc', 'nis', 'ai'] as const).flatMap((field) =>
    s[field] ? [`${field.toUpperCase()} : ${s[field]}`] : [],
  );
  return {
    name: s.name ?? 'Magasin',
    address: s.address ?? undefined,
    phone: s.phone ?? undefined,
    legal,
  };
}
