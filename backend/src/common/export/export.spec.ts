import { Workbook } from 'exceljs';
import {
  collectAll,
  ExportDocument,
  MAX_EXPORT_ROWS,
  MAX_PDF_ROWS,
  renderExport,
  section,
} from './export';

interface Row {
  name: string;
  amount: number;
  quantity: string;
  at: Date;
  due: string;
}

const doc: ExportDocument = {
  title: 'Ventes',
  subtitle: 'Du 01/09/2026 au 30/09/2026',
  filename: 'ventes_2026-09-01_2026-09-30',
  sections: [
    {
      title: 'Détail',
      columns: [
        { header: 'Client', value: (r: Row) => r.name },
        { header: 'Montant', kind: 'money', value: (r: Row) => r.amount },
        { header: 'Quantité', kind: 'quantity', value: (r: Row) => r.quantity },
        { header: 'Vendue le', kind: 'date', value: (r: Row) => r.at },
        { header: 'Échéance', kind: 'date', value: (r: Row) => r.due },
      ],
      rows: [
        {
          name: 'Électricité Benali',
          amount: 172_550,
          quantity: '12.500',
          // 23 h 30 UTC = 00 h 30 le lendemain à Alger.
          at: new Date('2026-09-14T23:30:00Z'),
          due: '2026-10-01',
        },
        {
          name: '=HYPERLINK("http://x")',
          amount: -5,
          quantity: '1.000',
          at: new Date('2026-09-15T08:00:00Z'),
          due: '',
        },
      ],
    },
  ],
};

describe('export', () => {
  it('CSV : séparateur `;`, virgule décimale, heure d’Alger, BOM', async () => {
    const file = await renderExport(doc, 'csv');
    const text = file.buffer.toString('utf8');

    expect(file.filename).toBe('ventes_2026-09-01_2026-09-30.csv');
    expect(text.charCodeAt(0)).toBe(0xfeff); // les accents s'ouvrent justes
    // Montant exact en ENTIERS : 172 550 centimes → 1725,50 ; −5 → -0,05.
    expect(text).toContain(
      'Électricité Benali;1725,50;12,500;15/09/2026 00:30;01/10/2026',
    );
    expect(text).toContain('-0,05');
  });

  /// Un nom de client commençant par `=` serait EXÉCUTÉ par le tableur à
  /// l'ouverture du CSV (injection de formule).
  it('CSV : une formule dans un texte est neutralisée', async () => {
    const text = (await renderExport(doc, 'csv')).buffer.toString('utf8');
    expect(text).toContain(`"'=HYPERLINK(""http://x"")"`);
    expect(text).not.toMatch(/(^|;)=HYPERLINK/m);
  });

  it('Excel : nombres sommables, dates réelles, texte jamais en formule', async () => {
    const file = await renderExport(doc, 'xlsx');
    expect(file.filename.endsWith('.xlsx')).toBe(true);

    const book = new Workbook();
    await book.xlsx.load(file.buffer as unknown as ArrayBuffer);
    const sheet = book.worksheets[0];
    // Titre, sous-titre, ligne vide, titre de section, en-têtes, puis données.
    const first = sheet.getRow(6);
    expect(first.getCell(1).value).toBe('Électricité Benali');
    expect(first.getCell(2).value).toBe(1725.5);
    expect(first.getCell(2).numFmt).toContain('DA');
    expect(first.getCell(3).value).toBe(12.5);
    // Heure MURALE d'Alger : Excel n'a pas de fuseau.
    expect((first.getCell(4).value as Date).toISOString()).toBe(
      '2026-09-15T00:30:00.000Z',
    );
    const second = sheet.getRow(7);
    expect(second.getCell(1).value).toBe('=HYPERLINK("http://x")');
    expect(second.getCell(1).formula).toBeUndefined();
    expect(second.getCell(5).value).toBeNull();
  });

  it('PDF : un vrai PDF, y compris sur plusieurs pages', async () => {
    const many: ExportDocument = {
      ...doc,
      sections: [
        { ...doc.sections[0], rows: Array(200).fill(doc.sections[0].rows[0]) },
      ],
    };
    const file = await renderExport(many, 'pdf');
    expect(file.buffer.subarray(0, 5).toString()).toBe('%PDF-');
    expect(file.contentType).toBe('application/pdf');
  });

  describe('collectAll', () => {
    /// Page par page, une vente passée entre deux lectures ferait sortir une
    /// ligne en double et en perdrait une autre. Une seule requête lit un état
    /// cohérent.
    it('lit la liste en UNE seule requête, jusqu’au plafond', async () => {
      const calls: [number, number][] = [];
      const rows = await collectAll(async (page, limit) => {
        calls.push([page, limit]);
        return { data: [1, 2, 3], meta: { total: 3 } };
      });
      expect(rows).toEqual([1, 2, 3]);
      expect(calls).toEqual([[1, MAX_EXPORT_ROWS]]);
    });

    it('refuse au-delà du plafond au lieu de tronquer en silence', async () => {
      await expect(
        collectAll(async () => ({
          data: [1],
          meta: { total: MAX_EXPORT_ROWS + 1 },
        })),
      ).rejects.toMatchObject({ response: { code: 'EXPORT_TOO_LARGE' } });
    });
  });

  it('PDF : refusé au-delà de MAX_PDF_ROWS, le tableur reste possible', async () => {
    const big: ExportDocument = {
      ...doc,
      sections: [
        {
          ...doc.sections[0],
          rows: Array(MAX_PDF_ROWS + 1).fill(doc.sections[0].rows[0]),
        },
      ],
    };
    await expect(renderExport(big, 'pdf')).rejects.toMatchObject({
      response: { code: 'EXPORT_TOO_LARGE' },
    });
    await expect(renderExport(big, 'csv')).resolves.toBeDefined();
  });

  it('CSV : formules après des blancs ou en pleine chasse aussi neutralisées', async () => {
    const names = [' =1+1', '＝1+1', '+213550000000', 'Normal'];
    const text = (
      await renderExport(
        {
          title: 't',
          filename: 'f',
          sections: [
            section({
              columns: [{ header: 'Nom', value: (n: string) => n }],
              rows: names,
            }),
          ],
        },
        'csv',
      )
    ).buffer.toString('utf8');
    expect(text).toContain("' =1+1");
    expect(text).toContain("'＝1+1");
    expect(text).toContain("'+213550000000");
    expect(text).toMatch(/^Normal$/m);
  });

  it('Excel : un jour pur s’affiche sans heure', async () => {
    const book = new Workbook();
    await book.xlsx.load(
      (await renderExport(doc, 'xlsx')).buffer as unknown as ArrayBuffer,
    );
    const row = book.worksheets[0].getRow(6);
    expect(row.getCell(5).numFmt).toBe('dd/mm/yyyy');
    expect(row.getCell(4).numFmt).toBe('dd/mm/yyyy hh:mm');
  });
});
