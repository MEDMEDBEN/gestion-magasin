import { DocumentPaper, StoreIdentity } from '../../settings/store-settings';
import { amountInWords } from './amount-in-words';
import { PdfDoc, renderPdf } from './pdf';

/// Document commercial UNIQUE du projet (décision MEDMEDBEN du 2026-10-12) :
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
const MUTED = '#555555';
const RULE = '#9a9a9a';
const HEAD_FILL = '#1d1d1d';
const ZEBRA = '#f1f1f1';

export function renderBusinessDocument(
  input: BusinessDocument,
): Promise<Buffer> {
  const a5 = input.paper === 'A5';
  const k = a5 ? 0.82 : 1; // échelle des polices et des espacements
  const margin = a5 ? 26 : 36;
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
      const bottom = () => doc.page.height - margin - 26 * k; // place du pied
      const font = (bold: boolean, size: number) =>
        doc.font(bold ? 'Helvetica-Bold' : 'Helvetica').fontSize(size * k);

      header(doc, input, left, width, k, font);
      parties(doc, input, left, width, k, font);
      table(doc, input, left, width, k, font, bottom);
      totals(doc, input, left, width, k, font, bottom);
      signatures(doc, input, left, width, k, font, bottom);
      footers(doc, input, left, width, k, margin, font);
    },
  );
}

type Font = (bold: boolean, size: number) => PdfDoc;

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
  const leftWidth = width * 0.56;
  // Identité du magasin.
  font(true, 15).fillColor(INK).text(store.name.toUpperCase(), left, top, {
    width: leftWidth,
  });
  font(false, 8.5).fillColor(MUTED);
  if (store.address) doc.text(store.address, { width: leftWidth });
  const contact = [
    store.phone ? `Tél : ${store.phone}` : null,
    store.email ?? null,
  ].filter(Boolean);
  if (contact.length) doc.text(contact.join('  ·  '), { width: leftWidth });
  if (store.legal.length) {
    font(false, 7.5).text(store.legal.join('   '), { width: leftWidth });
  }
  const leftBottom = doc.y;

  // Cartouche : titre sur fond noir, puis numéro / date / références.
  const boxX = left + width * 0.6;
  const boxW = width * 0.4;
  const titleH = 22 * k;
  doc.rect(boxX, top, boxW, titleH).fill(HEAD_FILL);
  font(true, 12)
    .fillColor('white')
    .text(input.title, boxX, top + 6 * k, { width: boxW, align: 'center' });
  const rows: [string, string][] = [['N°', input.number], ...input.meta];
  let y = top + titleH;
  const rowH = 14 * k;
  for (const [label, value] of rows) {
    doc.rect(boxX, y, boxW, rowH).lineWidth(0.6).strokeColor(RULE).stroke();
    font(false, 7.5)
      .fillColor(MUTED)
      .text(label, boxX + 4, y + 3.5 * k, { width: boxW * 0.35 });
    font(true, 8.5)
      .fillColor(INK)
      .text(value, boxX + boxW * 0.35, y + 3 * k, {
        width: boxW * 0.65 - 4,
        align: 'right',
        lineBreak: false,
        ellipsis: true,
      });
    y += rowH;
  }
  doc.y = Math.max(leftBottom, y) + 10 * k;
  doc
    .moveTo(left, doc.y)
    .lineTo(left + width, doc.y)
    .lineWidth(1.6)
    .strokeColor(INK)
    .stroke();
  doc.y += 8 * k;
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
  const gap = 10 * k;
  const count = input.parties.length;
  const boxW = (width - gap * (count - 1)) / count;
  const top = doc.y;
  let maxBottom = top;
  input.parties.forEach((party, i) => {
    const x = left + i * (boxW + gap);
    const labelH = 13 * k;
    doc.rect(x, top, boxW, labelH).fill('#e6e6e6');
    font(true, 7.5)
      .fillColor(INK)
      .text(party.label.toUpperCase(), x + 6, top + 3.5 * k, { width: boxW });
    font(true, 10).text(party.name, x + 6, top + labelH + 5 * k, {
      width: boxW - 12,
    });
    font(false, 8.5).fillColor(MUTED);
    for (const line of party.lines) doc.text(line, { width: boxW - 12 });
    const bottom = doc.y + 5 * k;
    maxBottom = Math.max(maxBottom, bottom);
  });
  input.parties.forEach((_, i) => {
    const x = left + i * (boxW + gap);
    doc
      .rect(x, top, boxW, maxBottom - top)
      .lineWidth(0.8)
      .strokeColor(INK)
      .stroke();
  });
  doc.y = maxBottom + 10 * k;
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
    { header: 'N°', width: 0.7, align: 'center' },
    ...input.columns,
  ];
  const total = columns.reduce((sum, c) => sum + c.width, 0);
  const widths = columns.map((c) => (c.width / total) * width);
  const pad = 4;

  const drawHeader = () => {
    const h = 16 * k;
    // Position FIXÉE avant d'écrire : chaque `text` déplace `doc.y`.
    const y = doc.y;
    doc.rect(left, y, width, h).fill(HEAD_FILL);
    let x = left;
    font(true, 8).fillColor('white');
    columns.forEach((c, i) => {
      doc.text(c.header, x + pad, y + 4.5 * k, {
        width: widths[i] - 2 * pad,
        align: c.align ?? 'left',
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
    font(false, 8.5);
    const height =
      Math.max(
        ...row.map((cell, i) =>
          doc.heightOfString(cell, { width: widths[i] - 2 * pad }),
        ),
      ) +
      7 * k;
    if (doc.y + height > bottom()) {
      doc.addPage();
      drawHeader();
    }
    const y = doc.y;
    if (index % 2 === 1) doc.rect(left, y, width, height).fill(ZEBRA);
    let x = left;
    font(false, 8.5).fillColor(INK);
    row.forEach((cell, i) => {
      doc.text(cell, x + pad, y + 3.5 * k, {
        width: widths[i] - 2 * pad,
        align: columns[i].align ?? 'left',
      });
      x += widths[i];
    });
    // Quadrillage : contour de la ligne et séparateurs de colonnes.
    doc.lineWidth(0.5).strokeColor(RULE);
    doc.rect(left, y, width, height).stroke();
    x = left;
    for (let i = 0; i < widths.length - 1; i++) {
      x += widths[i];
      doc
        .moveTo(x, y)
        .lineTo(x, y + height)
        .stroke();
    }
    doc.y = y + height;
  });
  if (input.rows.length === 0) {
    font(false, 8.5)
      .fillColor(MUTED)
      .text('Aucune ligne', left + pad, doc.y + 4 * k);
  }
  doc.y += 8 * k;
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
  const rowH = 15 * k;
  const needed =
    rows.length * rowH + (input.amountInWords !== undefined ? 30 * k : 0);
  if (doc.y + needed > bottom()) doc.addPage();
  const boxW = width * 0.42;
  const boxX = left + width - boxW;
  let y = doc.y;
  rows.forEach(([label, value, strong]) => {
    if (strong) doc.rect(boxX, y, boxW, rowH).fill(HEAD_FILL);
    doc
      .rect(boxX, y, boxW, rowH)
      .lineWidth(0.6)
      .strokeColor(strong ? HEAD_FILL : RULE)
      .stroke();
    font(!!strong, strong ? 9.5 : 8.5)
      .fillColor(strong ? 'white' : INK)
      .text(label, boxX + 5, y + 3.5 * k, {
        width: boxW * 0.64,
        lineBreak: false,
        ellipsis: true,
      });
    doc.text(value, boxX + boxW * 0.5, y + 3.5 * k, {
      width: boxW * 0.5 - 5,
      align: 'right',
      lineBreak: false,
    });
    y += rowH;
  });
  // Notes et mention à gauche des totaux.
  let noteY = doc.y;
  if (input.stamp) {
    font(true, 11)
      .fillColor('#b00020')
      .text(input.stamp, left, noteY, { width: width - boxW - 12 });
    noteY = doc.y + 4;
  }
  for (const note of input.notes ?? []) {
    font(false, 8)
      .fillColor(MUTED)
      .text(note, left, noteY, { width: width - boxW - 12 });
    noteY = doc.y + 2;
  }
  doc.y = Math.max(y, noteY) + 8 * k;
  if (input.amountInWords !== undefined) {
    const subject = input.wordsSubject ?? 'le présent document';
    font(false, 8.5)
      .fillColor(INK)
      .text(`Arrêté ${subject} à la somme de : `, left, doc.y, {
        width,
        continued: true,
      });
    font(true, 8.5).text(capitalize(amountInWords(input.amountInWords)) + '.');
    doc.y += 6 * k;
  }
}

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
  const h = 58 * k;
  if (doc.y + h + 8 > bottom()) doc.addPage();
  const gap = 10 * k;
  const boxW = (width - gap * (labels.length - 1)) / labels.length;
  const top = doc.y + 4 * k;
  labels.forEach((label, i) => {
    const x = left + i * (boxW + gap);
    doc.rect(x, top, boxW, h).lineWidth(0.6).strokeColor(RULE).stroke();
    font(true, 7.5)
      .fillColor(MUTED)
      .text(label.toUpperCase(), x + 5, top + 4 * k, { width: boxW - 10 });
  });
  doc.y = top + h + 6 * k;
}

/// Pied de chaque page : conditions du magasin, référence, « Page x / n ».
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
  for (let i = 0; i < range.count; i++) {
    doc.switchToPage(range.start + i);
    const y = doc.page.height - margin - 16 * k;
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
    doc.text(input.store.footer ?? '', left, y + 4 * k, {
      width: width * 0.7,
      lineBreak: false,
      ellipsis: true,
    });
    doc.text(
      `${input.number}  ·  Page ${i + 1} / ${range.count}`,
      left + width * 0.6,
      y + 4 * k,
      { width: width * 0.4, align: 'right', lineBreak: false },
    );
    doc.page.margins.bottom = savedBottom;
  }
}

function capitalize(text: string): string {
  return text.charAt(0).toUpperCase() + text.slice(1);
}
