import { Workbook } from 'exceljs';
import {
  collectAll,
  ExportDocument,
  MAX_EXPORT_ROWS,
  renderExport,
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
    it('lit toutes les pages de la liste existante', async () => {
      const all = Array.from({ length: 450 }, (_, i) => i);
      const pages: number[] = [];
      const rows = await collectAll(async (page, limit) => {
        pages.push(page);
        return {
          data: all.slice((page - 1) * limit, page * limit),
          meta: { total: all.length },
        };
      });
      expect(rows).toEqual(all);
      expect(pages).toEqual([1, 2, 3]);
    });

    it('refuse au-delà du plafond au lieu de tronquer en silence', async () => {
      await expect(
        collectAll(async () => ({
          data: [1],
          meta: { total: MAX_EXPORT_ROWS + 1 },
        })),
      ).rejects.toMatchObject({ response: { code: 'EXPORT_TOO_LARGE' } });
    });

    it('s’arrête si des lignes disparaissent entre deux pages', async () => {
      let calls = 0;
      const rows = await collectAll(async (page) => {
        calls++;
        return { data: page === 1 ? [1, 2] : [], meta: { total: 5 } };
      });
      expect(rows).toEqual([1, 2]);
      expect(calls).toBe(2);
    });
  });
});
