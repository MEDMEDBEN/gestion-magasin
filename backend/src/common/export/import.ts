import { HttpStatus } from '@nestjs/common';
import { CellValue, Workbook, Worksheet } from 'exceljs';
import { Readable } from 'stream';
import { BusinessException } from '../business.exception';
import { ErrorCode } from '../error-codes';

/// Lecture d'un fichier Excel ou CSV importé (spec §8quinquies) — le sens
/// inverse de `export.ts`, par la MÊME bibliothèque (`exceljs`,
/// CONVENTIONS.md). On ne lit que des VALEURS : une formule n'est jamais
/// évaluée, seul son dernier résultat enregistré est pris.

/// Au-delà, un import n'est plus une mise en place : c'est une migration à
/// préparer avec l'équipe.
export const MAX_IMPORT_ROWS = 1_000;

export interface ImportRow {
  /// Numéro de la ligne dans le FICHIER (1 = première ligne), pour que
  /// l'utilisateur retrouve la ligne fautive dans son tableur.
  line: number;
  /// En-tête (tel que défini par l'import) → texte de la cellule, nettoyé.
  cells: Record<string, string>;
}

const normalize = (text: string) =>
  text
    .normalize('NFD')
    .replace(/[̀-ͯ]/g, '')
    .replace(/\s+/g, ' ')
    .trim()
    .toLowerCase();

function cellText(value: CellValue): string {
  if (value === null || value === undefined) return '';
  if (value instanceof Date) return value.toISOString().slice(0, 10);
  if (typeof value === 'object') {
    if ('result' in value) return cellText(value.result as CellValue);
    if ('richText' in value) return value.richText.map((r) => r.text).join('');
    if ('text' in value) return String(value.text);
    return '';
  }
  // Un nombre issu d'une formule peut porter un résidu flottant
  // (1725.4999999…) : arrondi à 3 décimales, à la frontière d'entrée.
  if (typeof value === 'number' && !Number.isInteger(value)) {
    return String(Math.round(value * 1000) / 1000);
  }
  return String(value).trim();
}

/// Lit la première feuille d'un fichier Excel (`.xlsx`) ou CSV (`;` ou `,`).
/// La ligne d'en-tête est CHERCHÉE (dans les 20 premières lignes) : un modèle
/// téléchargé, ou un export du logiciel, se réimporte sans retoucher ses
/// lignes de titre. `headers` : les colonnes connues de l'import ; `required` :
/// celles qui doivent être présentes.
export async function readTable(
  buffer: Buffer,
  headers: string[],
  required: string[],
): Promise<ImportRow[]> {
  const sheet = await firstSheet(buffer);
  const wanted = new Map(headers.map((h) => [normalize(h), h]));
  let headerLine = 0;
  const columns = new Map<number, string>();
  for (let n = 1; n <= Math.min(20, sheet.rowCount); n++) {
    const found = new Map<number, string>();
    sheet.getRow(n).eachCell((cell, col) => {
      const header = wanted.get(normalize(cellText(cell.value)));
      if (header) found.set(col, header);
    });
    const names = new Set(found.values());
    if (required.every((h) => names.has(h))) {
      headerLine = n;
      found.forEach((header, col) => columns.set(col, header));
      break;
    }
  }
  if (headerLine === 0) {
    throw new BusinessException(
      ErrorCode.VALIDATION_FAILED,
      `En-têtes introuvables : le fichier doit contenir les colonnes ${required
        .map((h) => `« ${h} »`)
        .join(', ')} — partez du modèle à télécharger`,
      HttpStatus.UNPROCESSABLE_ENTITY,
    );
  }
  const rows: ImportRow[] = [];
  for (let n = headerLine + 1; n <= sheet.rowCount; n++) {
    const cells: Record<string, string> = {};
    const row = sheet.getRow(n);
    columns.forEach((header, col) => {
      const text = cellText(row.getCell(col).value);
      if (text !== '') cells[header] = text;
    });
    if (Object.keys(cells).length === 0) continue; // ligne vide
    rows.push({ line: n, cells });
    if (rows.length > MAX_IMPORT_ROWS) {
      throw new BusinessException(
        ErrorCode.VALIDATION_FAILED,
        `Fichier trop long : ${MAX_IMPORT_ROWS} lignes au plus par import — découpez-le`,
        HttpStatus.UNPROCESSABLE_ENTITY,
      );
    }
  }
  return rows;
}

async function firstSheet(buffer: Buffer): Promise<Worksheet> {
  const workbook = new Workbook();
  try {
    // Un .xlsx est une archive ZIP : il commence par « PK ».
    if (buffer.subarray(0, 2).toString('latin1') === 'PK') {
      await workbook.xlsx.load(buffer as unknown as ArrayBuffer);
    } else {
      const text = buffer.toString('utf8').replace(/^﻿/, '');
      const firstLine = text.split(/\r?\n/, 1)[0] ?? '';
      const delimiter =
        (firstLine.match(/;/g) ?? []).length >=
        (firstLine.match(/,/g) ?? []).length
          ? ';'
          : ',';
      await workbook.csv.read(Readable.from(text), {
        parserOptions: { delimiter },
      });
    }
  } catch {
    throw new BusinessException(
      ErrorCode.VALIDATION_FAILED,
      'Fichier illisible : attendu un classeur Excel (.xlsx) ou un CSV',
      HttpStatus.UNPROCESSABLE_ENTITY,
    );
  }
  const sheet = workbook.worksheets[0];
  if (!sheet) {
    throw new BusinessException(
      ErrorCode.VALIDATION_FAILED,
      'Fichier vide',
      HttpStatus.UNPROCESSABLE_ENTITY,
    );
  }
  return sheet;
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
/// `parseQuantity`. `null` si illisible.
export function parseImportQuantity(text: string): string | null {
  const cleaned = text.replace(/[\s  ]/g, '').replace(',', '.');
  return /^\d+(\.\d{1,3})?$/.test(cleaned) ? cleaned : null;
}
