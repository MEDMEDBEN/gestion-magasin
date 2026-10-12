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

const store = {
  name: 'Magasin',
  legal: [],
  ticketPaper: 'TICKET_80' as const,
  documentPaper: 'A4' as const,
};

describe('bordereau de transfert', () => {
  /// Il voyage avec la marchandise : jamais un prix, jamais un coût.
  it('aucune colonne d’argent', () => {
    const doc = transferDocument(transfer(), names, store);
    for (const c of doc.columns) {
      expect(c.header).not.toMatch(/prix|coût|montant|HT|TTC/i);
    }
  });

  it('étape non franchie : case vide, jamais « 0 »', () => {
    const doc = transferDocument(transfer(), names, store);
    const cell = (header: string, row = doc.rows[0]) =>
      row[doc.columns.findIndex((c) => c.header === header)];
    expect(cell('Expédié')).toBe('48,5');
    expect(cell('Reçu')).toBe('');

    const demande = transferDocument(
      transfer({ preparedAt: null, shippedAt: null, preparedById: null }),
      names,
      store,
    );
    expect(cell('Préparé', demande.rows[0])).toBe('');
  });

  /// L'expédition réécrit `preparedById` : une seule étape « Préparé /
  /// expédié », pour ne pas attribuer la préparation au mauvais membre.
  it('signataires : demandeur, expéditeur, réceptionnaire', () => {
    const doc = transferDocument(transfer(), names, store);
    expect(doc.signatures).toEqual([
      'Le demandeur',
      'L’expéditeur (dépôt)',
      'Le réceptionnaire',
    ]);
    expect(doc.parties[0].lines[0]).toContain('Préparé / expédié : Magasinier');
    expect(doc.parties.map((p) => p.name)).toEqual(['Dépôt', 'Magasin']);
  });

  it('aucun caractère hors des polices standard du PDF', () => {
    const doc = transferDocument(transfer(), names, store);
    // WinAnsi : Latin-1 plus quelques signes (·, —, …, ’) — pas de flèche.
    expect(JSON.stringify(doc)).not.toMatch(/[←-⇿]/);
  });
});
