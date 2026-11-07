import { DocumentPaper, StoreIdentity } from '../../settings/store-settings';
import { amountInWords } from './amount-in-words';
import { PdfDoc, renderPdf } from './pdf';

/// Document commercial UNIQUE du projet (décision MEDMEDBEN du 2026-10-12,
/// mise en page moderne le 2026-11-07 — voir `renderBusinessDocument`) :
/// facture, devis, bon de vente, de commande, de réception, de retour,
/// bordereau de transfert… La même structure « industrielle » partout, en
/// noir et gris (lisible sur toute imprimante laser) :
///  1. en-tête : identité du magasin à gauche ; cartouche du document à droite
///     (titre sur fond noir, numéro, date, références) ;
///  2. encadré de la partie (client, fournisseur, destination) ;
///  3. tableau quadrillé, en-tête répété à chaque page, lignes numérotées ;
///  4. totaux encadrés, somme en toutes lettres ;
///  5. cases de signature ; pied de page (conditions, « Page x / n »).
/// Format A4 ou A5, choisi dans Paramètres selon l'imprimante.

export interface DocumentColumn {
  header: string;
  /// Part de la largeur (les parts sont normalisées).
  width: number;
  align?: 'left' | 'right' | 'center';
}

export interface DocumentParty {
  /// « CLIENT », « FOURNISSEUR », « DESTINATION »…
  label: string;
  name: string;
  lines: string[];
}

export interface BusinessDocument {
  /// « FACTURE », « BON DE COMMANDE »…
  title: string;
  /// Titre des métadonnées du PDF.
  pdfTitle: string;
  number: string;
  /// Références du cartouche : [« Date », « 12/10/2026 14:05 »]…
  meta: [string, string][];
  store: StoreIdentity;
  parties: DocumentParty[];
  columns: DocumentColumn[];
  rows: string[][];
  /// Totaux, le dernier mis en avant : [libellé, montant, fort ?].
  totals: [string, string, boolean?][];
  /// Montant (centimes) écrit en toutes lettres sous les totaux.
  amountInWords?: number;
  /// Mot qui suit « Arrêté le présent … » (« la présente facture »…).
  wordsSubject?: string;
  notes?: string[];
  /// Libellés des cases de signature (vide : aucune).
  signatures?: string[];
  /// Mention en rouge (annulation…).
  stamp?: string;
  paper: DocumentPaper;
}

const INK = '#111111';
const MUTED = '#6b6b6b';
const RULE = '#d4d4d4';
const BLACK = '#000000';
const SOFT = '#f3f3f3';
const ZEBRA = '#fafafa';

/// Mise en page moderne en noir et blanc (demande MEDMEDBEN du 2026-11-07) :
/// bloc d'identité (pastille aux initiales, nom, coordonnées) à gauche, titre
/// du document en grand à droite ; bande de références ; parties à filet noir ;
/// tableau à en-tête noir et lignes fines ; totaux avec le total en bande
/// noire ; signatures posées en BAS de la page — le document occupe toute la
/// feuille ; pied de page sur chaque page.
export function renderBusinessDocument(
  input: BusinessDocument,
): Promise<Buffer> {
  const a5 = input.paper === 'A5';
  const k = a5 ? 0.82 : 1; // échelle des polices et des espacements
  const margin = a5 ? 28 : 40;
  return renderPdf(
    {
      size: input.paper,
      margin,
      bufferPages: true,
      info: { Title: input.pdfTitle },
    },
    (doc) => {
      const left = margin;
      const width = doc.page.width - 2 * margin;
      const bottom = () => doc.page.height - margin - 30 * k; // place du pied
      const font = (bold: boolean, size: number) =>
        doc.font(bold ? 'Helvetica-Bold' : 'Helvetica').fontSize(size * k);

      header(doc, input, left, width, k, font);
      metaBand(doc, input, left, width, k, font);
      parties(doc, input, left, width, k, font);
      table(doc, input, left, width, k, font, bottom);
      totals(doc, input, left, width, k, font, bottom);
      signatures(doc, input, left, width, k, font, bottom);
      footers(doc, input, left, width, k, margin, font);
    },
  );
}

type Font = (bold: boolean, size: number) => PdfDoc;

/// Initiales du magasin pour la pastille (« Shino Lighting » → « SL »).
function initials(name: string): string {
  const words = name.trim().split(/\s+/).filter(Boolean);
  const letters = words.slice(0, 2).map((w) => w.charAt(0).toUpperCase());
  return letters.join('') || '•';
}

function header(
  doc: PdfDoc,
  input: BusinessDocument,
  left: number,
  width: number,
  k: number,
  font: Font,
) {
  const { store } = input;
  const top = doc.y;
  const badge = 40 * k;
  const textX = left + badge + 12 * k;
  const leftWidth = width * 0.58 - badge - 12 * k;

  // Pastille aux initiales : la marque du magasin, en noir plein.
  doc.rect(left, top, badge, badge).fill(BLACK);
  font(true, 15)
    .fillColor('white')
    .text(initials(store.name), left, top + badge / 2 - 8 * k, {
      width: badge,
      align: 'center',
      lineBreak: false,
    });

  font(true, 17)
    .fillColor(INK)
    .text(store.name.toUpperCase(), textX, top - 1, {
      width: leftWidth,
      characterSpacing: 1.2,
    });
  font(false, 8.5).fillColor(MUTED);
  if (store.address) doc.text(store.address, textX, doc.y + 2 * k, { width: leftWidth });
  const contact = [
    store.phone ? `Tél. ${store.phone}` : null,
    store.email ?? null,
  ].filter(Boolean);
  if (contact.length) doc.text(contact.join('   ·   '), textX, doc.y, { width: leftWidth });
  if (store.legal.length) {
    font(false, 7).text(store.legal.join('   '), textX, doc.y + 2 * k, {
      width: leftWidth,
    });
  }
  const leftBottom = Math.max(doc.y, top + badge);

  // Titre du document, en grand, aligné à droite.
  const rightX = left + width * 0.55;
  const rightW = width * 0.45;
  font(true, 26)
    .fillColor(INK)
    .text(input.title, rightX, top - 4 * k, {
      width: rightW,
      align: 'right',
      characterSpacing: 2,
    });
  font(false, 9)
    .fillColor(MUTED)
    .text(`N° ${input.number}`, rightX, doc.y + 2 * k, {
      width: rightW,
      align: 'right',
    });
  const rightBottom = doc.y;

  doc.y = Math.max(leftBottom, rightBottom) + 14 * k;
  doc
    .moveTo(left, doc.y)
    .lineTo(left + width, doc.y)
    .lineWidth(2)
    .strokeColor(BLACK)
    .stroke();
  doc.y += 12 * k;
}

/// Bande de références : N°, date, échéance… en cellules étiquetées.
function metaBand(
  doc: PdfDoc,
  input: BusinessDocument,
  left: number,
  width: number,
  k: number,
  font: Font,
) {
  // Le numéro est déjà sous le titre : la bande ne porte que les références.
  const cells: [string, string][] = input.meta.length
    ? input.meta
    : [['Numéro', input.number]];
  const perRow = Math.min(cells.length, 4);
  const cellW = width / perRow;
  const cellH = 30 * k;
  for (let start = 0; start < cells.length; start += perRow) {
    const y = doc.y;
    doc.rect(left, y, width, cellH).fill(SOFT);
    cells.slice(start, start + perRow).forEach(([label, value], i) => {
      const x = left + i * cellW;
      if (i > 0) {
        doc
          .moveTo(x, y + 6 * k)
          .lineTo(x, y + cellH - 6 * k)
          .lineWidth(0.6)
          .strokeColor(RULE)
          .stroke();
      }
      font(true, 6.5)
        .fillColor(MUTED)
        .text(label.toUpperCase(), x + 10, y + 6 * k, {
          width: cellW - 20,
          characterSpacing: 0.8,
          lineBreak: false,
          ellipsis: true,
        });
      font(true, 9.5)
        .fillColor(INK)
        .text(value, x + 10, y + 15 * k, {
          width: cellW - 20,
          lineBreak: false,
          ellipsis: true,
        });
    });
    doc.y = y + cellH + 2 * k;
  }
  doc.y += 12 * k;
}

function parties(
  doc: PdfDoc,
  input: BusinessDocument,
  left: number,
  width: number,
  k: number,
  font: Font,
) {
  if (input.parties.length === 0) return;
  const gap = 14 * k;
  const count = input.parties.length;
  const boxW = (width - gap * (count - 1)) / count;
  const top = doc.y;
  let maxBottom = top;
  input.parties.forEach((party, i) => {
    const x = left + i * (boxW + gap) + 10;
    font(true, 6.5)
      .fillColor(MUTED)
      .text(party.label.toUpperCase(), x, top, {
        width: boxW - 10,
        characterSpacing: 0.8,
      });
    font(true, 11).fillColor(INK).text(party.name, x, doc.y + 3 * k, {
      width: boxW - 10,
    });
    font(false, 8.5).fillColor(MUTED);
    for (const line of party.lines) doc.text(line, x, doc.y + 1, { width: boxW - 10 });
    maxBottom = Math.max(maxBottom, doc.y);
  });
  // Filet noir à gauche de chaque partie.
  input.parties.forEach((_, i) => {
    const x = left + i * (boxW + gap);
    doc.rect(x, top, 3, maxBottom - top).fill(BLACK);
  });
  doc.y = maxBottom + 16 * k;
}

function table(
  doc: PdfDoc,
  input: BusinessDocument,
  left: number,
  width: number,
  k: number,
  font: Font,
  bottom: () => number,
) {
  // Colonne « N° » ajoutée : chaque ligne se cite par son numéro.
  const columns: DocumentColumn[] = [
    { header: '#', width: 0.6, align: 'center' },
    ...input.columns,
  ];
  const total = columns.reduce((sum, c) => sum + c.width, 0);
  const widths = columns.map((c) => (c.width / total) * width);
  const pad = 6;
  // La désignation en gras : c'est elle qu'on lit d'abord.
  const named = columns.findIndex((c) => c.header === 'Désignation');
  const strong = named >= 0 ? named : 1;

  const drawHeader = () => {
    const h = 20 * k;
    // Position FIXÉE avant d'écrire : chaque `text` déplace `doc.y`.
    const y = doc.y;
    doc.rect(left, y, width, h).fill(BLACK);
    let x = left;
    font(true, 7).fillColor('white');
    columns.forEach((c, i) => {
      doc.text(c.header.toUpperCase(), x + pad, y + 7 * k, {
        width: widths[i] - 2 * pad,
        align: c.align ?? 'left',
        characterSpacing: 0.6,
        lineBreak: false,
        ellipsis: true,
      });
      x += widths[i];
    });
    doc.y = y + h;
  };

  drawHeader();
  input.rows.forEach((cells, index) => {
    const row = [String(index + 1), ...cells];
    font(false, 9);
    const height =
      Math.max(
        ...row.map((cell, i) =>
          doc.heightOfString(cell, { width: widths[i] - 2 * pad }),
        ),
      ) +
      12 * k;
    if (doc.y + height > bottom()) {
      doc.addPage();
      drawHeader();
    }
    const y = doc.y;
    if (index % 2 === 1) doc.rect(left, y, width, height).fill(ZEBRA);
    let x = left;
    row.forEach((cell, i) => {
      font(i === strong, 9).fillColor(i === 0 ? MUTED : INK);
      doc.text(cell, x + pad, y + 6 * k, {
        width: widths[i] - 2 * pad,
        align: columns[i].align ?? 'left',
      });
      x += widths[i];
    });
    // Un filet fin sous la ligne, pas de quadrillage : plus lisible.
    doc
      .moveTo(left, y + height)
      .lineTo(left + width, y + height)
      .lineWidth(0.5)
      .strokeColor(RULE)
      .stroke();
    doc.y = y + height;
  });
  if (input.rows.length === 0) {
    font(false, 9)
      .fillColor(MUTED)
      .text('Aucune ligne', left + pad, doc.y + 6 * k);
  }
  // Filet noir de fin de tableau.
  doc
    .moveTo(left, doc.y)
    .lineTo(left + width, doc.y)
    .lineWidth(1.2)
    .strokeColor(BLACK)
    .stroke();
  doc.y += 14 * k;
}

function totals(
  doc: PdfDoc,
  input: BusinessDocument,
  left: number,
  width: number,
  k: number,
  font: Font,
  bottom: () => number,
) {
  const rows = input.totals;
  const rowH = 18 * k;
  const strongH = 28 * k;
  const needed =
    rows.length * rowH + strongH + (input.amountInWords !== undefined ? 44 * k : 0);
  if (doc.y + needed > bottom()) doc.addPage();
  const boxW = width * 0.42;
  const boxX = left + width - boxW;
  const top = doc.y;
  let y = top;
  rows.forEach(([label, value, strong]) => {
    if (strong) {
      // Le total à payer : une bande noire, en grand.
      doc.rect(boxX, y + 4 * k, boxW, strongH).fill(BLACK);
      font(true, 9)
        .fillColor('white')
        .text(label.toUpperCase(), boxX + 10, y + 4 * k + 10 * k, {
          width: boxW * 0.5,
          characterSpacing: 0.8,
          lineBreak: false,
          ellipsis: true,
        });
      font(true, 13).text(value, boxX + boxW * 0.4, y + 4 * k + 8 * k, {
        width: boxW * 0.6 - 10,
        align: 'right',
        lineBreak: false,
      });
      y += strongH + 4 * k;
      return;
    }
    font(false, 9)
      .fillColor(MUTED)
      .text(label, boxX + 10, y + 5 * k, {
        width: boxW * 0.6,
        lineBreak: false,
        ellipsis: true,
      });
    font(true, 9.5)
      .fillColor(INK)
      .text(value, boxX + boxW * 0.4, y + 5 * k, {
        width: boxW * 0.6 - 10,
        align: 'right',
        lineBreak: false,
      });
    doc
      .moveTo(boxX, y + rowH)
      .lineTo(boxX + boxW, y + rowH)
      .lineWidth(0.5)
      .strokeColor(RULE)
      .stroke();
    y += rowH;
  });

  // Notes et mention, à gauche des totaux.
  let noteY = top;
  const noteW = width - boxW - 24;
  if (input.stamp) {
    const stampH = 22 * k;
    doc.rect(left, noteY, noteW, stampH).lineWidth(1.5).strokeColor(BLACK).stroke();
    font(true, 11)
      .fillColor(BLACK)
      .text(input.stamp, left, noteY + 6 * k, {
        width: noteW,
        align: 'center',
        characterSpacing: 1,
      });
    noteY += stampH + 8 * k;
  }
  if ((input.notes ?? []).length) {
    font(true, 6.5)
      .fillColor(MUTED)
      .text('NOTES', left, noteY, { width: noteW, characterSpacing: 0.8 });
    noteY = doc.y + 3 * k;
    for (const note of input.notes ?? []) {
      font(false, 8.5).fillColor(INK).text(note, left, noteY, { width: noteW });
      noteY = doc.y + 3 * k;
    }
  }
  doc.y = Math.max(y, noteY) + 12 * k;

  if (input.amountInWords !== undefined) {
    const subject = input.wordsSubject ?? 'le présent document';
    const boxY = doc.y;
    font(false, 8.5);
    const text = `Arrêté ${subject} à la somme de : ${capitalize(amountInWords(input.amountInWords))}.`;
    const h = doc.heightOfString(text, { width: width - 24 }) + 16 * k;
    doc.rect(left, boxY, width, h).fill(SOFT);
    font(false, 8.5)
      .fillColor(INK)
      .text(`Arrêté ${subject} à la somme de : `, left + 12, boxY + 8 * k, {
        width: width - 24,
        continued: true,
      });
    font(true, 8.5).text(capitalize(amountInWords(input.amountInWords)) + '.');
    doc.y = boxY + h + 10 * k;
  }
}

/// Signatures : posées en BAS de la dernière page, pour que le document
/// occupe toute la feuille (une page à moitié vide fait brouillon).
function signatures(
  doc: PdfDoc,
  input: BusinessDocument,
  left: number,
  width: number,
  k: number,
  font: Font,
  bottom: () => number,
) {
  const labels = input.signatures ?? [];
  if (labels.length === 0) return;
  const h = 70 * k;
  if (doc.y + h + 12 > bottom()) doc.addPage();
  const top = Math.max(doc.y + 6 * k, bottom() - h - 8 * k);
  const gap = 24 * k;
  const boxW = (width - gap * (labels.length - 1)) / labels.length;
  labels.forEach((label, i) => {
    const x = left + i * (boxW + gap);
    font(true, 6.5)
      .fillColor(MUTED)
      .text(label.toUpperCase(), x, top, { width: boxW, characterSpacing: 0.8 });
    // Une ligne de signature, pas une boîte : plus sobre.
    doc
      .moveTo(x, top + h - 8 * k)
      .lineTo(x + boxW, top + h - 8 * k)
      .lineWidth(0.8)
      .strokeColor(INK)
      .stroke();
  });
  doc.y = top + h;
}

/// Pied de chaque page : coordonnées et conditions, référence, « Page x / n ».
function footers(
  doc: PdfDoc,
  input: BusinessDocument,
  left: number,
  width: number,
  k: number,
  margin: number,
  font: Font,
) {
  const range = doc.bufferedPageRange();
  const { store } = input;
  const line =
    store.footer ??
    [store.name, store.address, store.phone ? `Tél. ${store.phone}` : null]
      .filter(Boolean)
      .join('   ·   ');
  for (let i = 0; i < range.count; i++) {
    doc.switchToPage(range.start + i);
    const y = doc.page.height - margin - 18 * k;
    doc
      .moveTo(left, y)
      .lineTo(left + width, y)
      .lineWidth(0.6)
      .strokeColor(RULE)
      .stroke();
    // Écrire SOUS la marge basse : pdfkit ajouterait une page sinon.
    const savedBottom = doc.page.margins.bottom;
    doc.page.margins.bottom = 0;
    font(false, 7).fillColor(MUTED);
    doc.text(line, left, y + 6 * k, {
      width: width * 0.7,
      lineBreak: false,
      ellipsis: true,
    });
    doc.text(
      `${input.number}   ·   Page ${i + 1} / ${range.count}`,
      left + width * 0.6,
      y + 6 * k,
      { width: width * 0.4, align: 'right', lineBreak: false },
    );
    doc.page.margins.bottom = savedBottom;
  }
}

function capitalize(text: string): string {
  return text.charAt(0).toUpperCase() + text.slice(1);
}
