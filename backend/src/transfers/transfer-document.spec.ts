import { TransferDto } from './dto/transfer.dto';
import { transferDocument } from './transfer-document';

const names = {
  sku: () => 'CAB-3G25',
  product: () => 'Câble',
  unit: () => 'METRE',
  location: (id: string | null | undefined) =>
    id === 'dep' ? 'Dépôt' : 'Magasin',
  user: (id: string | null | undefined) =>
    ({ v: 'Vendeur', m: 'Magasinier' })[id ?? ''] ?? '',
};

const transfer = (over: Partial<TransferDto> = {}): TransferDto =>
  ({
    id: 't1',
    number: 'TRF-2026-00004',
    status: 'EN_TRANSIT',
    priority: 'NORMALE',
    fromLocationId: 'dep',
    toLocationId: 'mag',
    requestedById: 'v',
    preparedById: 'm',
    receivedById: null,
    requestedAt: new Date('2026-09-27T08:00:00Z'),
    preparedAt: new Date('2026-09-27T09:00:00Z'),
    shippedAt: new Date('2026-09-27T10:00:00Z'),
    receivedAt: null,
    comment: null,
    updatedAt: new Date('2026-09-27T10:00:00Z'),
    lines: [
      {
        id: 'l1',
        productId: 'p1',
        requestedQuantity: '50.000',
        preparedQuantity: '48.500',
        shippedQuantity: '48.500',
        receivedQuantity: '0.000',
      },
    ],
    ...over,
  }) as TransferDto;

describe('bon de transfert', () => {
  /// Il voyage avec la marchandise : jamais un prix, jamais un coût.
  it('aucune colonne d’argent', () => {
    const doc = transferDocument(transfer(), names);
    for (const s of doc.sections) {
      for (const c of s.columns) {
        expect(c.kind).not.toBe('money');
        expect(c.header).not.toMatch(/prix|coût|montant|HT|TTC/i);
      }
    }
  });

  it('étape non franchie : case vide, jamais « 0,000 »', () => {
    const lines = transferDocument(transfer(), names).sections[0];
    const row = lines.rows[0];
    const cell = (header: string) =>
      lines.columns.find((c) => c.header === header)!.value(row);
    expect(cell('Expédié')).toBe('48.500');
    expect(cell('Reçu')).toBeNull();

    const demande = transferDocument(
      transfer({ preparedAt: null, shippedAt: null, preparedById: null }),
      names,
    ).sections[0];
    const preparedCell = demande.columns
      .find((c) => c.header === 'Préparé')!
      .value(demande.rows[0]);
    expect(preparedCell).toBeNull();
  });

  /// L'expédition réécrit `preparedById` : une seule ligne « Préparé /
  /// expédié », pour ne pas attribuer la préparation au mauvais membre.
  it('signataires : préparation et expédition sur une seule ligne', () => {
    const steps = transferDocument(transfer(), names).sections[1];
    const rows = steps.rows as { step: string; who: string }[];
    expect(rows.map((r) => r.step)).toEqual([
      'Demandé',
      'Préparé / expédié',
      'Reçu',
    ]);
    expect(rows[1].who).toBe('Magasinier');
  });

  it('sous-titre sans caractère hors des polices standard du PDF', () => {
    const doc = transferDocument(transfer(), names);
    expect(doc.subtitle).toBe('De Dépôt vers Magasin · En transit');
    // WinAnsi : Latin-1 plus quelques signes (·, —, …, ’) — pas de flèche.
    expect(doc.subtitle).not.toMatch(/[←-⇿]/);
  });
});
