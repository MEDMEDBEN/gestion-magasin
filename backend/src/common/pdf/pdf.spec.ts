import { formatDA, formatDateTime, renderPdf } from './pdf';

describe('pdf', () => {
  it('formatDA : centimes entiers, séparateur de milliers, négatifs', () => {
    expect(formatDA(0)).toBe('0,00 DA');
    expect(formatDA(5)).toBe('0,05 DA');
    expect(formatDA(172550)).toBe('1 725,50 DA');
    expect(formatDA(123456789)).toBe('1 234 567,89 DA');
    expect(formatDA(-1000)).toBe('-10,00 DA');
  });

  it('formatDateTime : heure d’Alger (UTC+1)', () => {
    expect(formatDateTime(new Date('2026-12-31T23:30:00Z'))).toBe(
      '01/01/2027 00:30',
    );
  });

  it('renderPdf produit un vrai PDF, et rejette si le dessin échoue', async () => {
    const pdf = await renderPdf({}, (doc) => doc.text('Réception é à ç'));
    expect(pdf.subarray(0, 5).toString()).toBe('%PDF-');
    await expect(
      renderPdf({}, () => {
        throw new Error('boom');
      }),
    ).rejects.toThrow('boom');
  });
});
