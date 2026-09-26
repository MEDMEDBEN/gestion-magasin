import { HttpStatus, StreamableFile } from '@nestjs/common';
import { ApiProperty } from '@nestjs/swagger';
import { IsIn } from 'class-validator';
import { Workbook } from 'exceljs';
import { BusinessException } from '../business.exception';
import { ErrorCode } from '../error-codes';
import { formatDA, PdfDoc, renderPdf } from '../pdf/pdf';

/// Exports de fichiers (spec §8quinquies) — le SEUL endroit du projet qui écrit
/// de l'Excel ou du CSV (CONVENTIONS.md : `exceljs`, qui écrit aussi le CSV). Le
/// PDF passe par le moteur unique `common/pdf/pdf.ts`.
///
/// Un export n'est qu'une autre MISE EN FORME d'une lecture qui existe déjà :
/// l'appelant lui passe les lignes rendues par le service de la liste ou du
/// rapport, avec les mêmes gardes et le même cloisonnement. Un fichier n'est
/// pas un contournement de permission.

export const EXPORT_FORMATS = ['xlsx', 'csv', 'pdf'] as const;
export type ExportFormat = (typeof EXPORT_FORMATS)[number];

/// Types MIME des trois formats, pour le contrat OpenAPI (`@ApiProduces`).
export const EXPORT_TYPES = [
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'text/csv',
  'application/pdf',
];

export class ExportFormatQueryDto {
  @ApiProperty({ enum: EXPORT_FORMATS })
  @IsIn(EXPORT_FORMATS)
  format!: ExportFormat;
}

/// Ce que représente une cellule — il décide de sa mise en forme dans chaque
/// format :
/// - `money` : entier en CENTIMES (règle 4), converti en dinars à l'écriture ;
/// - `quantity` : décimale en chaîne (`"12.500"`), jamais un flottant en entrée ;
/// - `date` : un horodatage (`Date` ou ISO complet), montré à l'heure d'Alger —
///   ou un jour pur `AAAA-MM-JJ` (échéance), montré tel quel ;
/// - `integer` : un compteur ; `text` : tout le reste.
export type CellKind = 'text' | 'integer' | 'money' | 'quantity' | 'date';
export type CellValue = string | number | Date | null | undefined;

export interface ExportColumn<Row> {
  header: string;
  kind?: CellKind;
  value: (row: Row) => CellValue;
}

export interface ExportSection<Row = never> {
  /// Titre de la section (un rapport en a plusieurs : totaux, par jour…).
  title?: string;
  columns: ExportColumn<Row>[];
  rows: Row[];
}

/// Section typée par ses lignes : `value` reçoit le bon type de ligne.
export function section<Row>(value: ExportSection<Row>): ExportSection<Row> {
  return value;
}

export interface ExportDocument {
  title: string;
  /// Ligne sous le titre : période, filtre appliqué.
  subtitle?: string;
  /// Nom du fichier SANS extension, ex. `ventes-2026-09-01_2026-09-30`.
  filename: string;
  // Chaque section a son propre type de ligne ; le document les mélange.
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  sections: ExportSection<any>[];
}

export interface ExportFile {
  buffer: Buffer;
  filename: string;
  contentType: string;
}

/// Au-delà, un export n'est plus un document qu'on lit : c'est une copie de la
/// base, qui tient le serveur le temps de la générer. On demande de resserrer le
/// filtre plutôt que de tronquer en silence.
export const MAX_EXPORT_ROWS = 10_000;

/// Lit TOUTES les pages d'une liste paginée existante, avec ses filtres et ses
/// gardes — c'est ce qui fait suivre le cloisonnement à l'export.
export async function collectAll<Row>(
  fetchPage: (
    page: number,
    limit: number,
  ) => Promise<{ data: Row[]; meta: { total: number } }>,
): Promise<Row[]> {
  const limit = 200;
  const first = await fetchPage(1, limit);
  assertExportable(first.meta.total);
  const rows = [...first.data];
  for (let page = 2; rows.length < first.meta.total; page++) {
    const next = await fetchPage(page, limit);
    if (next.data.length === 0) break; // lignes supprimées entre deux pages
    rows.push(...next.data);
  }
  return rows;
}

export function assertExportable(total: number): void {
  if (total > MAX_EXPORT_ROWS) {
    throw new BusinessException(
      ErrorCode.EXPORT_TOO_LARGE,
      `Export trop volumineux : ${total} lignes, ${MAX_EXPORT_ROWS} au plus — resserrez la période ou le filtre`,
      HttpStatus.BAD_REQUEST,
    );
  }
}

export async function renderExport(
  doc: ExportDocument,
  format: ExportFormat,
): Promise<ExportFile> {
  switch (format) {
    case 'xlsx':
      return {
        buffer: await toXlsx(doc),
        filename: `${doc.filename}.xlsx`,
        contentType:
          'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      };
    case 'csv':
      return {
        buffer: await toCsv(doc),
        filename: `${doc.filename}.csv`,
        contentType: 'text/csv; charset=utf-8',
      };
    case 'pdf':
      return {
        buffer: await toPdf(doc),
        filename: `${doc.filename}.pdf`,
        contentType: 'application/pdf',
      };
  }
}

/// Réponse HTTP d'un export : pièce jointe, jamais affichée dans le navigateur.
export function exportResponse(file: ExportFile): StreamableFile {
  return new StreamableFile(file.buffer, {
    type: file.contentType,
    disposition: `attachment; filename="${file.filename}"`,
  });
}

// ── Mise en forme des cellules ────────────────────────────────────────────

const DAY_ONLY = /^\d{4}-\d{2}-\d{2}$/;

/// Montant exact en dinars, « 1234,56 », calculé en ENTIERS (jamais `/ 100`
/// flottant) : c'est le texte qui voyage dans le CSV.
function dinars(centimes: number): string {
  const sign = centimes < 0 ? '-' : '';
  const abs = Math.abs(centimes);
  return `${sign}${Math.trunc(abs / 100)},${(abs % 100).toString().padStart(2, '0')}`;
}

/// Parties de l'heure d'Alger d'un horodatage : le serveur tourne en UTC.
function algiersParts(value: Date | string) {
  const parts = new Intl.DateTimeFormat('fr-FR', {
    timeZone: 'Africa/Algiers',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    hourCycle: 'h23',
  }).formatToParts(new Date(value));
  const get = (type: string) => parts.find((p) => p.type === type)!.value;
  return {
    y: get('year'),
    m: get('month'),
    d: get('day'),
    hh: get('hour'),
    mm: get('minute'),
  };
}

/// `AAAA-MM-JJ` → `JJ/MM/AAAA`, pour un sous-titre de période.
export function frenchDay(day: string): string {
  return dateText(day);
}

function dateText(value: Date | string): string {
  if (typeof value === 'string' && DAY_ONLY.test(value)) {
    const [y, m, d] = value.split('-');
    return `${d}/${m}/${y}`;
  }
  const p = algiersParts(value);
  return `${p.d}/${p.m}/${p.y} ${p.hh}:${p.mm}`;
}

/// Texte d'une cellule pour le CSV et le PDF.
function cellText(kind: CellKind, value: CellValue, forCsv: boolean): string {
  if (value === null || value === undefined || value === '') return '';
  switch (kind) {
    case 'money':
      return forCsv ? dinars(Number(value)) : formatDA(Number(value));
    case 'quantity':
      // Décimale en chaîne : on change le séparateur, on ne recalcule rien.
      return String(value).replace('.', ',');
    case 'date':
      return dateText(value as Date | string);
    case 'integer':
      return String(value);
    case 'text': {
      const text = String(value);
      // Injection de formule : un nom de client « =HYPERLINK(...) » serait
      // EXÉCUTÉ par le tableur à l'ouverture du CSV. L'apostrophe le neutralise.
      return forCsv && /^[=+\-@\t\r]/.test(text) ? `'${text}` : text;
    }
  }
}

// ── Excel ─────────────────────────────────────────────────────────────────

const XLSX_FORMATS: Partial<Record<CellKind, string>> = {
  money: '#,##0.00 "DA"',
  quantity: '#,##0.###',
  date: 'dd/mm/yyyy hh:mm',
};

/// Valeur NUMÉRIQUE d'une cellule Excel, pour que le tableur puisse sommer et
/// trier. Le fichier est un affichage : il ne revient jamais dans le système.
function xlsxValue(kind: CellKind, value: CellValue): CellValue {
  if (value === null || value === undefined || value === '') return null;
  switch (kind) {
    case 'money':
      return Number(value) / 100;
    case 'quantity':
      return Number(value);
    case 'date': {
      if (typeof value === 'string' && DAY_ONLY.test(value)) {
        return new Date(`${value}T00:00:00Z`);
      }
      // Excel n'a pas de fuseau : on écrit l'heure MURALE d'Alger.
      const p = algiersParts(value as Date | string);
      return new Date(`${p.y}-${p.m}-${p.d}T${p.hh}:${p.mm}:00Z`);
    }
    default:
      return value;
  }
}

async function toXlsx(doc: ExportDocument): Promise<Buffer> {
  const workbook = new Workbook();
  // Nom d'onglet : 31 caractères au plus, sans `\ / ? * [ ] :`.
  const sheet = workbook.addWorksheet(
    doc.title.replace(/[\\/?*[\]:]/g, ' ').slice(0, 31),
  );
  sheet.addRow([doc.title]).font = { bold: true, size: 14 };
  if (doc.subtitle) sheet.addRow([doc.subtitle]);

  const widths: number[] = [];
  for (const section of doc.sections) {
    sheet.addRow([]);
    if (section.title) sheet.addRow([section.title]).font = { bold: true };
    sheet.addRow(section.columns.map((c) => c.header)).font = { bold: true };
    section.columns.forEach((c, i) => {
      widths[i] = Math.max(widths[i] ?? 10, c.header.length + 2);
    });
    for (const row of section.rows) {
      const added = sheet.addRow(
        section.columns.map((c) => xlsxValue(c.kind ?? 'text', c.value(row))),
      );
      section.columns.forEach((c, i) => {
        const format = XLSX_FORMATS[c.kind ?? 'text'];
        if (format) added.getCell(i + 1).numFmt = format;
      });
    }
  }
  widths.forEach((width, i) => {
    sheet.getColumn(i + 1).width = Math.min(width, 40);
  });
  return Buffer.from(await workbook.xlsx.writeBuffer());
}

// ── CSV ───────────────────────────────────────────────────────────────────

/// CSV « à la française » : séparateur `;` et virgule décimale, que le tableur
/// d'un poste réglé en français ouvre sans assistant ; BOM pour les accents.
async function toCsv(doc: ExportDocument): Promise<Buffer> {
  const workbook = new Workbook();
  const sheet = workbook.addWorksheet('export');
  sheet.addRow([doc.title]);
  if (doc.subtitle) sheet.addRow([doc.subtitle]);
  for (const section of doc.sections) {
    sheet.addRow([]);
    if (section.title) sheet.addRow([section.title]);
    sheet.addRow(section.columns.map((c) => c.header));
    for (const row of section.rows) {
      sheet.addRow(
        section.columns.map((c) =>
          cellText(c.kind ?? 'text', c.value(row), true),
        ),
      );
    }
  }
  return Buffer.from(
    await workbook.csv.writeBuffer({
      formatterOptions: { delimiter: ';', writeBOM: true },
    }),
  );
}

// ── PDF ───────────────────────────────────────────────────────────────────

const NUMERIC: CellKind[] = ['integer', 'money', 'quantity'];

/// Tableau simple, colonnes de largeur égale, en-tête répété à chaque page.
/// Paysage au-delà de 5 colonnes.
function toPdf(doc: ExportDocument): Promise<Buffer> {
  const wide = doc.sections.some((s) => s.columns.length > 5);
  return renderPdf(
    { size: 'A4', layout: wide ? 'landscape' : 'portrait', margin: 36 },
    (pdf: PdfDoc) => {
      const left = pdf.page.margins.left;
      const width = pdf.page.width - left - pdf.page.margins.right;
      const bottom = pdf.page.height - pdf.page.margins.bottom;

      pdf.font('Helvetica-Bold').fontSize(14).text(doc.title);
      if (doc.subtitle) pdf.font('Helvetica').fontSize(9).text(doc.subtitle);

      for (const section of doc.sections) {
        pdf.moveDown(0.8);
        if (section.title) {
          if (pdf.y + 40 > bottom) pdf.addPage();
          pdf.font('Helvetica-Bold').fontSize(11).text(section.title, left);
          pdf.moveDown(0.2);
        }
        const columnWidth = width / section.columns.length;
        const drawRow = (cells: string[], bold: boolean) => {
          if (pdf.y + 14 > bottom) {
            pdf.addPage();
            if (!bold)
              drawRow(
                section.columns.map((c) => c.header),
                true,
              );
          }
          const y = pdf.y;
          pdf.font(bold ? 'Helvetica-Bold' : 'Helvetica').fontSize(8);
          cells.forEach((cell, i) => {
            pdf.text(cell, left + i * columnWidth + 2, y, {
              width: columnWidth - 4,
              height: 10,
              lineBreak: false,
              ellipsis: true,
              align: NUMERIC.includes(section.columns[i].kind ?? 'text')
                ? 'right'
                : 'left',
            });
          });
          pdf.y = y + 12;
        };
        drawRow(
          section.columns.map((c) => c.header),
          true,
        );
        for (const row of section.rows) {
          drawRow(
            section.columns.map((c) =>
              cellText(c.kind ?? 'text', c.value(row), false),
            ),
            false,
          );
        }
        if (section.rows.length === 0) {
          pdf.font('Helvetica-Oblique').fontSize(8).text('Aucune ligne', left);
        }
      }
    },
  );
}
