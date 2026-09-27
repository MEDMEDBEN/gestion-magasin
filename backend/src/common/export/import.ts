import { HttpStatus } from '@nestjs/common';
import { CellValue } from 'exceljs';
import { Worker } from 'worker_threads';
import { BusinessException } from '../business.exception';
import { ErrorCode } from '../error-codes';
import { QUANTITY_PATTERN } from '../quantity';

/// Lecture d'un fichier Excel ou CSV importé (spec §8quinquies) — le sens
/// inverse de `export.ts`, par la MÊME bibliothèque (`exceljs`,
/// CONVENTIONS.md). On ne lit que des VALEURS : une formule n'est jamais
/// évaluée, seul son dernier résultat enregistré est pris.

/// Au-delà, un import n'est plus une mise en place : c'est une migration à
/// préparer avec l'équipe.
export const MAX_IMPORT_ROWS = 1_000;

/// Lignes où chercher l'en-tête, et colonnes lues : au-delà, on ignore.
const HEADER_SEARCH_ROWS = 20;
const MAX_COLUMNS = 100;

/// Un .xlsx de 2 Mo peut se décompresser en gigaoctets (bombe ZIP) : il est
/// ouvert dans un worker à mémoire et durée BORNÉES, tué au-delà — jamais
/// dans le processus du serveur.
const READER_MEMORY_MB = 256;
const READER_TIMEOUT_MS = 15_000;

export interface ImportRow {
  /// Numéro de la ligne dans le FICHIER (1 = première ligne), pour que
  /// l'utilisateur retrouve la ligne fautive dans son tableur.
  line: number;
  /// En-tête (tel que défini par l'import) → texte de la cellule, nettoyé.
  cells: Record<string, string>;
  /// Cellule illisible (erreur #N/A, formule jamais calculée) : la ligne est
  /// rapportée en erreur, jamais importée avec une case vide à la place.
  error?: string;
}

export interface ImportTable {
  rows: ImportRow[];
  /// Colonnes de la ligne d'en-tête que l'import ne connaît pas (faute de
  /// frappe, « Prix TTC »…) : signalées, pour ne pas les perdre en silence.
  ignored: string[];
}

/// Clé de comparaison d'un texte saisi : sans accents, casse ni espaces
/// superflus (« Électricité  BENALI » = « electricite benali »).
export const normalize = (text: string) =>
  text
    .normalize('NFD')
    .replace(/[̀-ͯ]/g, '')
    .replace(/\s+/g, ' ')
    .trim()
    .toLowerCase();

class UnreadableCell extends Error {}

function cellText(value: CellValue): string {
  if (value === null || value === undefined) return '';
  if (value instanceof Date) return value.toISOString().slice(0, 10);
  if (typeof value === 'object') {
    if ('error' in value) {
      throw new UnreadableCell(`cellule en erreur (${String(value.error)})`);
    }
    if ('formula' in value || 'sharedFormula' in value) {
      if (value.result === undefined) {
        throw new UnreadableCell(
          'formule jamais calculée — ouvrez puis enregistrez le fichier dans le tableur',
        );
      }
      return cellText(value.result as CellValue);
    }
    if ('richText' in value) {
      return value.richText
        .map((r) => r.text)
        .join('')
        .trim();
    }
    if ('text' in value) return String(value.text).trim();
    return '';
  }
  // Un nombre issu d'une formule peut porter un résidu flottant
  // (1725.4999999…) : arrondi à 3 décimales, à la frontière d'entrée.
  if (typeof value === 'number' && !Number.isInteger(value)) {
    return String(Math.round(value * 1000) / 1000);
  }
  return String(value).trim();
}

const invalid = (message: string) =>
  new BusinessException(
    ErrorCode.VALIDATION_FAILED,
    message,
    HttpStatus.UNPROCESSABLE_ENTITY,
  );

/// Lit la première feuille d'un fichier Excel (`.xlsx`) ou CSV (`;` ou `,`).
/// La ligne d'en-tête est CHERCHÉE (dans les 20 premières lignes) : un modèle
/// téléchargé, ou un export du logiciel, se réimporte sans retoucher ses
/// lignes de titre. `headers` : les colonnes connues de l'import ; `required` :
/// celles qui doivent être présentes.
export async function readTable(
  buffer: Buffer,
  headers: string[],
  required: string[],
): Promise<ImportTable> {
  const sheet = await readSheet(buffer);
  const wanted = new Map(headers.map((h) => [normalize(h), h]));
  const quiet = (value: CellValue) => {
    try {
      return cellText(value);
    } catch {
      return '';
    }
  };
  let start = -1;
  const columns = new Map<number, string>();
  const ignored: string[] = [];
  for (const [i, { line, values }] of sheet.rows.entries()) {
    if (line > HEADER_SEARCH_ROWS) break;
    const found = new Map<number, string>();
    const unknown: string[] = [];
    values.forEach((value, col) => {
      const name = quiet(value);
      const header = wanted.get(normalize(name));
      if (header) found.set(col, header);
      else if (name !== '') unknown.push(name);
    });
    const names = new Set(found.values());
    if (required.every((h) => names.has(h))) {
      start = i + 1;
      found.forEach((header, col) => columns.set(col, header));
      ignored.push(...unknown);
      break;
    }
  }
  if (start < 0) {
    throw invalid(
      `En-têtes introuvables : le fichier doit contenir les colonnes ${required
        .map((h) => `« ${h} »`)
        .join(', ')} — partez du modèle à télécharger`,
    );
  }
  const tooLong = invalid(
    `Fichier trop long : ${MAX_IMPORT_ROWS} lignes au plus par import — découpez-le`,
  );
  if (sheet.truncated) throw tooLong;
  const rows: ImportRow[] = [];
  for (const { line, values } of sheet.rows.slice(start)) {
    const cells: Record<string, string> = {};
    const problems: string[] = [];
    columns.forEach((header, col) => {
      try {
        const value = cellText(values[col] ?? null);
        if (value !== '') cells[header] = value;
      } catch (error) {
        if (!(error instanceof UnreadableCell)) throw error;
        problems.push(`${header} : ${error.message}`);
      }
    });
    if (Object.keys(cells).length === 0 && problems.length === 0) continue;
    rows.push({
      line,
      cells,
      ...(problems.length > 0 && { error: problems.join(' ; ') }),
    });
    if (rows.length > MAX_IMPORT_ROWS) throw tooLong;
  }
  return { rows, ignored };
}

/// Texte d'un CSV : UTF-8 s'il l'est VRAIMENT, sinon Windows-1252 — l'encodage
/// d'un CSV enregistré par Excel sous Windows (« Réf » y est l'octet E9).
function decodeCsv(buffer: Buffer): string {
  let text: string;
  try {
    text = new TextDecoder('utf-8', { fatal: true }).decode(buffer);
  } catch {
    text = new TextDecoder('windows-1252').decode(buffer);
  }
  return text.replace(/^﻿/, '');
}

interface Sheet {
  /// Lignes NON VIDES du fichier, dans l'ordre ; `values[col]` (1 = colonne A).
  rows: { line: number; values: CellValue[] }[];
  /// Le fichier a plus de lignes qu'un import n'en accepte.
  truncated: boolean;
}

type ReaderResult =
  | { unreadable: true }
  | { sheet: boolean; rows: Sheet['rows']; truncated: boolean }
  | 'limit';

/// Code du worker (JavaScript brut : il ne passe pas par la compilation
/// TypeScript). Il ne parcourt que les lignes EXISTANTES — une seule cellule
/// en A1048576 n'en fait pas un million — et ne rend que des valeurs.
/// Tout CSV est lu en TEXTE (`map`) : « 0550123456 » garde son zéro.
const READER = `
const { parentPort, workerData: w } = require('worker_threads');
const { Readable } = require('stream');
const { Workbook } = require(w.exceljs);
(async () => {
  const book = new Workbook();
  if (w.csv === null) await book.xlsx.load(w.buffer);
  else await book.csv.read(Readable.from([w.csv]), {
    map: (value) => value,
    parserOptions: { delimiter: w.delimiter },
  });
  const sheet = book.worksheets[0];
  const rows = [];
  let truncated = false;
  if (sheet) sheet.eachRow((row, line) => {
    if (rows.length >= w.maxRows) truncated = true;
    else rows.push({ line, values: row.values.slice(0, w.maxColumns + 1) });
  });
  parentPort.postMessage({ sheet: Boolean(sheet), rows, truncated });
})().catch(() => parentPort.postMessage({ unreadable: true }));
`;

async function readSheet(buffer: Buffer): Promise<Sheet> {
  // Un .xlsx est une archive ZIP : il commence par « PK ».
  const xlsx = buffer.subarray(0, 2).toString('latin1') === 'PK';
  let csv: string | null = null;
  let delimiter = ';';
  if (!xlsx) {
    csv = decodeCsv(buffer);
    const firstLine = csv.split(/\r?\n/, 1)[0] ?? '';
    const count = (c: string) => firstLine.split(c).length - 1;
    if (count(',') > count(';')) delimiter = ',';
  }
  const result = await new Promise<ReaderResult>((resolve) => {
    const worker = new Worker(READER, {
      eval: true,
      workerData: {
        exceljs: require.resolve('exceljs'),
        buffer: xlsx ? buffer : null,
        csv,
        delimiter,
        // En-tête cherché + lignes de données : au-delà, le fichier est refusé.
        maxRows: HEADER_SEARCH_ROWS + MAX_IMPORT_ROWS + 1,
        maxColumns: MAX_COLUMNS,
      },
      resourceLimits: { maxOldGenerationSizeMb: READER_MEMORY_MB },
    });
    let settled = false;
    const done = (value: ReaderResult) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      void worker.terminate();
      resolve(value);
    };
    const timer = setTimeout(() => done('limit'), READER_TIMEOUT_MS);
    worker.once('message', (message: ReaderResult) => done(message));
    // Mémoire dépassée (ERR_WORKER_OUT_OF_MEMORY) ou arrêt brutal.
    worker.once('error', () => done('limit'));
    worker.once('exit', () => done('limit'));
  });
  if (result === 'limit') {
    throw invalid(
      'Fichier trop lourd à lire : gardez seulement les lignes à importer, ou découpez-le',
    );
  }
  if ('unreadable' in result) {
    throw invalid(
      'Fichier illisible : attendu un classeur Excel (.xlsx) ou un CSV',
    );
  }
  if (!result.sheet || result.rows.length === 0) throw invalid('Fichier vide');
  return { rows: result.rows, truncated: result.truncated };
}

/// Montant en dinars écrit par un humain ou un tableur (« 1 725,50 »,
/// « 1725.5 », « 1 725,50 DA ») → CENTIMES entiers, par arithmétique sur le
/// TEXTE (règle 4 : jamais de flottant). `null` si illisible.
export function parseMoney(text: string): number | null {
  const cleaned = text.replace(/DA$/i, '').replace(/[\s  ]/g, '');
  const match = /^(\d+)(?:[.,](\d{1,2}))?$/.exec(cleaned);
  if (!match) return null;
  const cents =
    Number(match[1]) * 100 + Number((match[2] ?? '').padEnd(2, '0'));
  return Number.isSafeInteger(cents) ? cents : null;
}

/// Quantité (« 12,5 », « 12.500 ») → chaîne décimale au point, pour
/// `parseQuantity` — dont elle reprend le motif (bornes comprises), sans
/// négatif. `null` si illisible.
export function parseImportQuantity(text: string): string | null {
  const cleaned = text.replace(/[\s  ]/g, '').replace(',', '.');
  return !cleaned.startsWith('-') && QUANTITY_PATTERN.test(cleaned)
    ? cleaned
    : null;
}
