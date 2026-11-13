import { barcodePng, symbology } from '../common/barcode/barcode';
import { Prisma } from '../generated/prisma/client';
import {
  Label,
  LABEL,
  labelFor,
  MIN_MODULE_MM,
  moduleWidthMm,
  renderLabels,
} from './labels';

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
  /// Sans TVA (retirée le 2026-10-05) : le prix en rayon est le prix du
  /// tarif, exactement celui payé en caisse.
  it('prix affiché = prix du tarif, sans TVA', () => {
    expect(labelFor(cable, 145).priceTtc).toBe(145);
    expect(labelFor(cable, 145000).priceTtc).toBe(145000);
  });

  it('symbologie : EAN-13 si 13 chiffres à clé juste, Code128 sinon', async () => {
    expect(symbology('2000000000015')).toBe('ean13');
    expect(symbology('4006381333931')).toBe('ean13'); // code fabricant réel
    expect(symbology('2000000000016')).toBe('code128'); // clé fausse
    expect(symbology('E2E-ABC-1')).toBe('code128');
    expect(symbology('12345678')).toBe('code128');
    for (const code of ['2000000000015', 'E2E-ABC-1', '2000000000016']) {
      const png = await barcodePng(code);
      expect(png.subarray(1, 4).toString()).toBe('PNG');
    }
  });

  /// Barres trop fines = étiquette que la douchette ne lit pas : refusée en
  /// nommant le produit, au lieu d'être imprimée muette.
  it('code trop long pour l’étiquette : refusé, en nommant le produit', async () => {
    const court = labelFor({ ...cable, barcode: 'DJ-16-C' }, 1000);
    const long = labelFor(
      { ...cable, name: 'Gaine ICTA', barcode: 'X'.repeat(40) },
      1000,
    );
    await expect(renderLabels([court])).resolves.toBeInstanceOf(Buffer);
    await expect(renderLabels([court, long])).rejects.toMatchObject({
      response: {
        message: expect.stringContaining('Gaine ICTA') as unknown as string,
      },
    });
    // Un EAN-13 (code interne ou fabricant) est TOUJOURS lisible.
    expect(
      moduleWidthMm(await barcodePng('2000000000015'), LABEL),
    ).toBeGreaterThanOrEqual(MIN_MODULE_MM);
  });

  /// Audit sécurité : l'image doit être embarquée UNE fois par document.
  it('1 000 étiquettes du même produit : PDF léger et rapide', async () => {
    const start = Date.now();
    const pdf = await renderLabels(
      Array<Label>(1000).fill(labelFor(cable, 145000)),
    );
    expect(pdf.length).toBeLessThan(1_000_000); // ~630 o par page, l'image une fois;
    expect(Date.now() - start).toBeLessThan(8_000);
  });

  /// Décision MEDMEDBEN du 2026-11-13 : UNE étiquette par page, 35 × 45 mm
  /// en portrait, quel que soit le poste.
  it('une étiquette 35 × 45 mm portrait par page', async () => {
    const label: Label = labelFor(cable, 145000);
    const pdf = await renderLabels(Array<Label>(3).fill(label));
    expect(pages(pdf)).toBe(3);
    // 35 mm = 99,21 pt ; 45 mm = 127,56 pt.
    expect(pdf.toString('latin1')).toMatch(
      /MediaBox \[0 0 99\.21\d* 127\.55\d*/,
    );
  });
});
