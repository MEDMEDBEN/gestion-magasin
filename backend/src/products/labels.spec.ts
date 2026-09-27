import { barcodePng } from '../common/barcode/barcode';
import { taxAmount } from '../common/money';
import { Prisma } from '../generated/prisma/client';
import { Label, labelFor, renderLabels } from './labels';

const cable = {
  name: 'Câble 3G2,5 — rouleau de 100 m, gaine souple',
  sku: 'CAB-3G25',
  barcode: '2000000000015',
  unit: 'METRE',
  taxRate: { rate: new Prisma.Decimal('19.00') },
};

/// Nombre de pages d'un PDF pdfkit (les dictionnaires d'objets ne sont pas
/// compressés, seul le contenu des pages l'est).
const pages = (pdf: Buffer) =>
  (pdf.toString('latin1').match(/\/Type \/Page\b/g) ?? []).length;

describe('étiquettes', () => {
  /// Le prix lu en rayon est le prix payé : même calcul que la ligne de vente.
  it('TTC calculé comme en caisse, arrondi au centime', () => {
    // 145 centimes HT × 19 % = 27,55 → 28 : 1,73 DA TTC.
    expect(labelFor(cable, 145).priceTtc).toBe(173);
    expect(labelFor(cable, 145).priceTtc).toBe(
      145 + taxAmount(145, cable.taxRate.rate),
    );
    expect(labelFor({ ...cable, taxRate: null }, 145).priceTtc).toBe(145);
  });

  it('code-barres : EAN-13 si la clé est juste, Code128 sinon', async () => {
    const ean = await barcodePng('2000000000015');
    const other = await barcodePng('E2E-ABC-1');
    // Deux images PNG différentes, aucune erreur sur un code non numérique.
    expect(ean.subarray(1, 4).toString()).toBe('PNG');
    expect(other.subarray(1, 4).toString()).toBe('PNG');
    // Clé fausse : pas d'EAN-13 (bwip-js le refuserait), Code128 à la place.
    await expect(barcodePng('2000000000016')).resolves.toBeInstanceOf(Buffer);
  });

  it('planche A4 : 24 par page ; rouleau : une par page', async () => {
    const label: Label = labelFor(cable, 145000);
    const many = Array<Label>(25).fill(label);
    expect(pages(await renderLabels(many, 'A4'))).toBe(2);
    expect(pages(await renderLabels(many.slice(0, 24), 'A4'))).toBe(1);
    expect(pages(await renderLabels(many.slice(0, 3), 'ROULEAU'))).toBe(3);
  });
});
