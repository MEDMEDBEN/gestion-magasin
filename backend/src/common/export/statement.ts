import { assertExportable, ExportDocument, section } from './export';

/// Relevé de compte (P1 bis n°21n) : mouvements datés et solde courant, pour
/// un client ou un fournisseur. Mise en forme SEULEMENT (PDF / Excel / CSV par
/// `renderExport`) : le service fournit les mouvements, lus par les MÊMES
/// composantes que la dette qu'il affiche — le dernier solde du relevé EST
/// cette dette.

export interface StatementEntry {
  at: Date;
  piece: string | null;
  label: string;
  /// Centimes qui AUGMENTENT le solde (ce qui est dû).
  plus: number;
  /// Centimes qui le DIMINUENT.
  minus: number;
}

export function statementDocument(input: {
  title: string;
  subtitle: string;
  filename: string;
  /// En-têtes des colonnes « augmente » / « diminue » (Débit / Crédit…).
  plusHeader: string;
  minusHeader: string;
  entries: StatementEntry[];
}): ExportDocument {
  assertExportable(input.entries.length);
  // Tri stable par date : à égalité, l'ordre fourni (la vente avant son
  // règlement) est gardé.
  const sorted = [...input.entries].sort(
    (a, b) => a.at.getTime() - b.at.getTime(),
  );
  let balance = 0;
  const rows = sorted.map((e) => {
    balance += e.plus - e.minus;
    return { ...e, balance };
  });
  return {
    title: input.title,
    subtitle: input.subtitle,
    filename: input.filename,
    sections: [
      section({
        columns: [
          { header: 'Date', kind: 'date', value: (r) => r.at },
          { header: 'Pièce', value: (r) => r.piece },
          { header: 'Libellé', value: (r) => r.label },
          {
            header: input.plusHeader,
            kind: 'money',
            value: (r) => (r.plus ? r.plus : null),
          },
          {
            header: input.minusHeader,
            kind: 'money',
            value: (r) => (r.minus ? r.minus : null),
          },
          { header: 'Solde', kind: 'money', value: (r) => r.balance },
        ],
        rows,
      }),
    ],
  };
}

/// Libellé lisible d'un mode de paiement (« (espèces) », jamais « (especes) »).
export const PAYMENT_METHOD_LABEL: Record<string, string> = {
  ESPECES: 'espèces',
  // Paiement par chèque RETIRÉ le 2026-10-05 (sandbox/cheques) : le libellé
  // reste pour afficher l'historique éventuel d'avant.
  CHEQUE: 'chèque',
  VIREMENT: 'virement',
  CARTE: 'carte',
  AUTRE: 'autre',
};

/// Nom de fichier sûr (en-tête Content-Disposition) : lettres, chiffres,
/// tirets — `releve-client-electricite-benali-2026-09-28`.
export function statementFilename(kind: string, name: string, day: string) {
  const slug = name
    .normalize('NFD')
    .replace(/\p{M}/gu, '') // accents détachés par NFD
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 40);
  return `releve-${kind}-${slug ? `${slug}-` : ''}${day}`;
}

/// Un montant signé (règlement, contre-passation négative) vers plus / minus :
/// positif = il diminue le solde.
export function signedMinus(amount: number): { plus: number; minus: number } {
  return amount >= 0 ? { plus: 0, minus: amount } : { plus: -amount, minus: 0 };
}
