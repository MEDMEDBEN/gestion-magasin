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
  'email',
  'footer',
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

/// Formats d'impression (décision MEDMEDBEN du 2026-10-12) : choisis une fois
/// dans Paramètres, selon les imprimantes du magasin.
export const TICKET_PAPERS = ['TICKET_80', 'TICKET_58', 'A5', 'A4'] as const;
export type TicketPaper = (typeof TICKET_PAPERS)[number];
export const DOCUMENT_PAPERS = ['A4', 'A5'] as const;
export type DocumentPaper = (typeof DOCUMENT_PAPERS)[number];

export interface PrintSettings {
  ticketPaper: TicketPaper;
  documentPaper: DocumentPaper;
  labelWidthMm: number;
  labelHeightMm: number;
}

export const PRINT_DEFAULTS: PrintSettings = {
  ticketPaper: 'TICKET_80',
  documentPaper: 'A4',
  labelWidthMm: 50,
  labelHeightMm: 30,
};

export async function printSettings(db: Db): Promise<PrintSettings> {
  const row = await db.storeSettings.findUnique({ where: { id: 1 } });
  if (!row) return PRINT_DEFAULTS;
  return {
    ticketPaper: (TICKET_PAPERS as readonly string[]).includes(row.ticketPaper)
      ? (row.ticketPaper as TicketPaper)
      : PRINT_DEFAULTS.ticketPaper,
    documentPaper: (DOCUMENT_PAPERS as readonly string[]).includes(
      row.documentPaper,
    )
      ? (row.documentPaper as DocumentPaper)
      : PRINT_DEFAULTS.documentPaper,
    labelWidthMm: row.labelWidthMm,
    labelHeightMm: row.labelHeightMm,
  };
}

/// Identité FIGÉE (facture émise, avoir) + formats d'impression ACTUELS.
export async function withCurrentPrint(
  db: Db,
  identity: StoreIdentity,
): Promise<StoreIdentity> {
  const print = await printSettings(db);
  return {
    ...identity,
    ticketPaper: print.ticketPaper,
    documentPaper: print.documentPaper,
  };
}

export interface StoreIdentity {
  name: string;
  address?: string;
  phone?: string;
  email?: string;
  /// Mentions légales (NIF, RC, NIS, AI) déjà mises en forme, une par entrée.
  legal: string[];
  /// Pied de page des bons et tickets (conditions, remerciement).
  footer?: string;
  ticketPaper: TicketPaper;
  documentPaper: DocumentPaper;
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
  const print = await printSettings(db);
  return {
    name: s.name ?? 'Magasin',
    address: s.address ?? undefined,
    phone: s.phone ?? undefined,
    email: s.email ?? undefined,
    legal,
    footer: s.footer ?? undefined,
    ticketPaper: print.ticketPaper,
    documentPaper: print.documentPaper,
  };
}
