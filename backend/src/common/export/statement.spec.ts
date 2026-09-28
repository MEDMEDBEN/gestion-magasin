import { signedMinus, statementDocument, statementFilename } from './statement';

describe('relevé de compte', () => {
  it('solde courant dans l’ordre des dates, stable à égalité', () => {
    const at = (d: string) => new Date(`2026-09-${d}T10:00:00Z`);
    const doc = statementDocument({
      title: 'Relevé',
      subtitle: '',
      filename: 'r',
      plusHeader: 'Débit',
      minusHeader: 'Crédit',
      entries: [
        { at: at('03'), piece: null, label: 'règlement', ...signedMinus(400) },
        { at: at('01'), piece: 'TK', label: 'vente', plus: 1000, minus: 0 },
        { at: at('03'), piece: null, label: 'annulé', ...signedMinus(-400) },
      ],
    });
    const rows = doc.sections[0].rows as { label: string; balance: number }[];
    expect(rows.map((r) => [r.label, r.balance])).toEqual([
      ['vente', 1000],
      ['règlement', 600],
      ['annulé', 1000],
    ]);
  });

  it('nom de fichier sans accent ni caractère d’en-tête', () => {
    expect(
      statementFilename('client', 'Électricité "Benali" & Fils', '2026-09-28'),
    ).toBe('releve-client-electricite-benali-fils-2026-09-28');
    expect(statementFilename('client', '«»', '2026-09-28')).toBe(
      'releve-client-2026-09-28',
    );
  });
});
