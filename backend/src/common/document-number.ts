import { Prisma } from '../generated/prisma/client';

type Db = Prisma.TransactionClient;

/// Année civile en Algérie (Africa/Algiers) — les compteurs repartent à 1 le
/// 1er janvier LOCAL, pas UTC.
export function localYear(date: Date): number {
  return Number(
    new Intl.DateTimeFormat('en', {
      timeZone: 'Africa/Algiers',
      year: 'numeric',
    }).format(date),
  );
}

/// Date civile en Algérie, « AAAA-MM-JJ » (échéances, jour de caisse).
export function localDate(date: Date): string {
  return new Intl.DateTimeFormat('en-CA', {
    timeZone: 'Africa/Algiers',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).format(date);
}

/// INSTANT où commence la journée civile algérienne en cours.
///
/// C'est la borne à utiliser contre un HORODATAGE RÉEL (`soldAt`, `receivedAt`) :
/// `parseApiDate(localDate(now))` rend minuit UTC, soit 01 h à Alger — une vente
/// encaissée entre minuit et 01 h serait comptée sur la veille. Pour un champ de
/// DATE PURE (`dueDate`, enregistré à minuit UTC), c'est l'inverse : garder
/// `parseApiDate(localDate(...))`, qui compare bien comme pour comme.
export function startOfLocalDay(now = new Date()): Date {
  // Heure murale d'Alger relue comme si elle était UTC : l'écart avec l'instant
  // réel est le décalage du fuseau, sans le coder en dur.
  const wall = new Date(
    `${new Intl.DateTimeFormat('sv-SE', {
      timeZone: 'Africa/Algiers',
      dateStyle: 'short',
      timeStyle: 'medium',
    })
      .format(now)
      .replace(' ', 'T')}Z`,
  );
  const offsetMs = wall.getTime() - now.getTime();
  return new Date(new Date(`${localDate(now)}T00:00:00Z`).getTime() - offsetMs);
}

/// Numéro séquentiel d'un document, attribué SERVEUR dans la transaction de
/// l'appelant (règle 11) : le compteur de l'année est verrouillé par l'UPDATE,
/// donc deux demandes simultanées ne peuvent pas obtenir le même numéro ni
/// laisser de trou.
export async function nextDocumentNumber(
  tx: Db,
  documentType:
    | 'FACTURE'
    | 'DEVIS'
    | 'BON_COMMANDE'
    | 'TRANSFERT'
    | 'RECEPTION'
    | 'INVENTAIRE',
  prefix: string,
  digits: number,
  year = localYear(new Date()),
): Promise<string> {
  await tx.$executeRaw`
    INSERT INTO "InvoiceCounter" ("id", "documentType", "year", "lastNumber", "updatedAt")
    VALUES (gen_random_uuid(), ${documentType}::"DocumentType", ${year}, 0, now())
    ON CONFLICT ("documentType", "year") DO NOTHING`;
  const [counter] = await tx.$queryRaw<{ lastNumber: number }[]>`
    UPDATE "InvoiceCounter" SET "lastNumber" = "lastNumber" + 1, "updatedAt" = now()
    WHERE "documentType" = ${documentType}::"DocumentType" AND "year" = ${year}
    RETURNING "lastNumber"`;
  return `${prefix}-${year}-${String(counter.lastNumber).padStart(digits, '0')}`;
}
