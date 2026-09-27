import { Workbook } from 'exceljs';
import { parseImportQuantity, parseMoney, readTable } from './import';

describe('lecture d’un import', () => {
  /// Règle 4 : des centimes ENTIERS, calculés sur le texte, jamais en flottant.
  it('montants en dinars → centimes entiers', () => {
    expect(parseMoney('1 725,50')).toBe(172550);
    expect(parseMoney('1725.5')).toBe(172550);
    expect(parseMoney('1 725,50 DA')).toBe(172550);
    expect(parseMoney('0,07')).toBe(7);
    // 0,1 + 0,2 en flottant vaut 0,30000000000000004 : ici, 30 exactement.
    expect(parseMoney('0,30')).toBe(30);
    expect(parseMoney('10')).toBe(1000);
    for (const bad of ['dix', '-5', '1,234', '1.2.3', '']) {
      expect(parseMoney(bad)).toBeNull();
    }
  });

  it('quantités décimales, virgule acceptée', () => {
    expect(parseImportQuantity('12,5')).toBe('12.5');
    expect(parseImportQuantity('100')).toBe('100');
    expect(parseImportQuantity('0,125')).toBe('0.125');
    for (const bad of ['-1', '1,2345', 'beaucoup']) {
      expect(parseImportQuantity(bad)).toBeNull();
    }
  });

  it('CSV : séparateur `;` ou `,` détecté, lignes vides ignorées', async () => {
    for (const text of [
      'Nom;Téléphone\nA;1\n\nB;2',
      'Nom,Téléphone\nA,1\nB,2',
    ]) {
      const rows = await readTable(
        Buffer.from(text),
        ['Nom', 'Téléphone'],
        ['Nom'],
      );
      expect(rows.map((r) => r.cells)).toEqual([
        { Nom: 'A', Téléphone: '1' },
        { Nom: 'B', Téléphone: '2' },
      ]);
    }
  });

  /// Un tableur piégé : la formule n'est JAMAIS évaluée, seul son dernier
  /// résultat enregistré est lu ; les en-têtes sont cherchés sous le titre.
  it('Excel : en-tête cherché, formule lue par son résultat', async () => {
    const book = new Workbook();
    const sheet = book.addWorksheet('Clients');
    sheet.addRow(['Import clients']);
    sheet.addRow([]);
    sheet.addRow(['Nom', 'Plafond de crédit']);
    sheet.addRow(['Benali', { formula: 'SUM(1,2)', result: 3 }]);
    const buffer = Buffer.from(await book.xlsx.writeBuffer());

    const rows = await readTable(buffer, ['Nom', 'Plafond de crédit'], ['Nom']);
    expect(rows).toEqual([
      { line: 4, cells: { Nom: 'Benali', 'Plafond de crédit': '3' } },
    ]);
  });

  it('fichier illisible ou sans en-tête : refus explicite', async () => {
    await expect(
      readTable(Buffer.from('PK\u0003\u0004 pas un zip'), ['Nom'], ['Nom']),
    ).rejects.toMatchObject({
      response: {
        message: expect.stringContaining('illisible') as unknown as string,
      },
    });
    await expect(
      readTable(Buffer.from('Foo;Bar\n1;2'), ['Nom'], ['Nom']),
    ).rejects.toMatchObject({
      response: {
        message: expect.stringContaining('« Nom »') as unknown as string,
      },
    });
  });
});
