import { numbersOf, readInvoiceLines } from './invoice-scan';

const products = [
  {
    id: 'd16',
    name: 'Disjoncteur 16A',
    sku: 'DIS-16A',
    barcode: '6111234567890',
  },
  { id: 'cab', name: 'Câble 2,5 mm²', sku: 'CAB-25', barcode: '6110000000011' },
];

describe('lecture de facture (P2 n°24)', () => {
  it('nombres au format français : milliers et décimales', () => {
    expect(numbersOf('10 1 200,00 12 000,00')).toEqual([10, 1200, 12000]);
    expect(numbersOf('2,5 145,50')).toEqual([2.5, 145.5]);
    expect(numbersOf('1.200,50')).toEqual([1200.5]);
  });

  it('produit par référence, quantité et prix vérifiés par le total', () => {
    const [line] = readInvoiceLines(
      'DIS-16A Disjoncteur 16A 10 1 200,00 12 000,00',
      products,
    );
    expect(line).toMatchObject({
      productId: 'd16',
      quantity: '10.000',
      unitPriceHt: 120000,
    });
  });

  it('produit par son nom (accents ignorés), chiffres du nom écartés', () => {
    const [line] = readInvoiceLines(
      'CABLE 2,5 MM² 100 45,00 4 500,00',
      products,
    );
    expect(line).toMatchObject({
      productId: 'cab',
      quantity: '100.000',
      unitPriceHt: 4500,
    });
  });

  it('ligne inconnue avec des nombres : proposée sans produit ; en-tête ignoré', () => {
    const lines = readInvoiceLines(
      'FACTURE N° 2026\nGaine ICTA 20 12 35,00 420,00\nMerci',
      products,
    );
    expect(lines).toHaveLength(1);
    expect(lines[0]).toMatchObject({
      productId: null,
      quantity: '12.000',
      unitPriceHt: 3500,
    });
  });

  /// Audits n°24 : quantité suivie d'un prix à 3 chiffres (pas un millier),
  /// millions, reconnaissance en mots entiers.
  it('« 5 350,00 1 750,00 » : 5 × 350,00, confirmé par le total', () => {
    const [line] = readInvoiceLines('DIS-16A 5 350,00 1 750,00', products);
    expect(line).toMatchObject({ quantity: '5.000', unitPriceHt: 35000 });
    expect(numbersOf('1 200 000,00')).toEqual([1200000]);
  });

  it('un nom court n’est reconnu qu’en mot entier (« Vis » ≠ « Devis »)', () => {
    const vis = [{ id: 'vis', name: 'Vis', sku: 'V', barcode: '1' }];
    expect(
      readInvoiceLines('Devis n 12 du 03 2026', vis)[0]?.productId ?? null,
    ).toBeNull();
    expect(readInvoiceLines('Vis 100 2,00 200,00', vis)[0]).toMatchObject({
      productId: 'vis',
      quantity: '100.000',
      unitPriceHt: 200,
    });
  });
});
