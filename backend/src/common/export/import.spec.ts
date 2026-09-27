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
      expect(rows.rows.map((r) => r.cells)).toEqual([
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
    expect(rows.rows).toEqual([
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

  /// Un CSV est lu en TEXTE : ni le zéro d'un téléphone, ni celui d'un code
  /// fabricant ne disparaissent (sans `map`, exceljs en faisait des nombres).
  it('CSV : zéros de tête conservés', async () => {
    const { rows } = await readTable(
      Buffer.from('Nom;Téléphone;Code\nA;0550123456;0123456789012'),
      ['Nom', 'Téléphone', 'Code'],
      ['Nom'],
    );
    expect(rows[0].cells).toEqual({
      Nom: 'A',
      Téléphone: '0550123456',
      Code: '0123456789012',
    });
  });

  /// Un CSV enregistré par Excel sous Windows est en Windows-1252.
  it('CSV Windows-1252 : accents lus', async () => {
    const latin1 = Buffer.from('Référence;Nom\nCAB;Câble', 'latin1');
    const { rows } = await readTable(latin1, ['Référence', 'Nom'], ['Nom']);
    expect(rows[0].cells).toEqual({ Référence: 'CAB', Nom: 'Câble' });
  });

  it('colonne inconnue signalée, jamais perdue en silence', async () => {
    const { ignored } = await readTable(
      Buffer.from('Nom;Prix TTC\nA;10'),
      ['Nom'],
      ['Nom'],
    );
    expect(ignored).toEqual(['Prix TTC']);
  });

  /// Une cellule en erreur ou une formule jamais calculée : la LIGNE est en
  /// erreur, jamais importée avec une case vide.
  it('Excel : cellule illisible → ligne en erreur', async () => {
    const book = new Workbook();
    const sheet = book.addWorksheet('Clients');
    sheet.addRow(['Nom', 'Plafond de crédit']);
    sheet.addRow(['A', { error: '#N/A' }]);
    sheet.addRow(['B', { formula: 'SUM(1,2)' }]);
    const buffer = Buffer.from(await book.xlsx.writeBuffer());

    const { rows } = await readTable(
      buffer,
      ['Nom', 'Plafond de crédit'],
      ['Nom'],
    );
    expect(rows[0].error).toContain('#N/A');
    expect(rows[1].error).toContain('jamais calculée');
  });

  /// Une seule cellule en A1048576 : l'ancien lecteur parcourait le million
  /// de lignes (mémoire du serveur épuisée). Seules les lignes existantes.
  it('Excel creux : une cellule en A1048576 ne coûte rien', async () => {
    const book = new Workbook();
    const sheet = book.addWorksheet('Clients');
    sheet.addRow(['Nom']);
    sheet.addRow(['A']);
    sheet.getCell('A1048576').value = 'Z';
    const buffer = Buffer.from(await book.xlsx.writeBuffer());

    const started = Date.now();
    const { rows } = await readTable(buffer, ['Nom'], ['Nom']);
    expect(rows.map((r) => r.line)).toEqual([2, 1048576]);
    expect(Date.now() - started).toBeLessThan(5_000);
  });

  it('trop de lignes : refus, sans tout lire', async () => {
    const text = ['Nom', ...Array.from({ length: 1_100 }, (_, i) => `C${i}`)];
    await expect(
      readTable(Buffer.from(text.join('\n')), ['Nom'], ['Nom']),
    ).rejects.toMatchObject({
      response: {
        message: expect.stringContaining('trop long') as unknown as string,
      },
    });
  });

  it('quantité : mêmes bornes que `parseQuantity`', () => {
    expect(parseImportQuantity('99999999999')).toBe('99999999999');
    expect(parseImportQuantity('999999999999')).toBeNull();
  });

  it('en-tête : apostrophe du clavier = apostrophe typographique', async () => {
    const { rows } = await readTable(
      Buffer.from("Nom;Prix d'achat HT\nA;10"),
      ['Nom', 'Prix d’achat HT'],
      ['Nom'],
    );
    expect(rows[0].cells).toEqual({ Nom: 'A', 'Prix d’achat HT': '10' });
  });
});
