import { HttpStatus } from '@nestjs/common';
import { barcodePng } from '../common/barcode/barcode';
import { BusinessException } from '../common/business.exception';
import { ErrorCode } from '../common/error-codes';
import {
  formatDA,
  openImage,
  PdfDoc,
  renderPdf,
  UNIT_LABEL,
} from '../common/pdf/pdf';

/// Étiquettes à coller sur les produits exposés (spec §8ter), par le moteur PDF
/// unique. Deux supports : planche A4 pour l'imprimante de bureau, rouleau pour
/// l'imprimante thermique.
export const LABEL_FORMATS = ['A4', 'ROULEAU'] as const;
export type LabelFormat = (typeof LABEL_FORMATS)[number];

export interface Label {
  name: string;
  sku: string;
  barcode: string;
  /// Prix TTC unitaire en centimes, calculé comme en caisse.
  priceTtc: number;
  unit: string;
}

/// Étiquette d'un produit au prix de son tarif : sans TVA (`NO_TAX`), le
/// prix lu en rayon est EXACTEMENT celui payé en caisse.
export function labelFor(
  product: {
    name: string;
    sku: string;
    barcode: string;
    unit: string;
  },
  price: number,
): Label {
  return {
    name: product.name,
    sku: product.sku,
    barcode: product.barcode,
    priceTtc: price,
    unit: product.unit,
  };
}

const MM = 72 / 25.4;

/// Planche « 24 étiquettes » 70 × 37 mm sans marge, la plus courante en
/// papeterie. Le ROULEAU, lui, prend la taille réglée dans Paramètres
/// (décision MEDMEDBEN du 2026-10-12 : l'étiquette de SON imprimante).
const SHEET = { cols: 3, rows: 8, width: 70 * MM, height: 37.125 * MM };

/// Taille d'une étiquette en rouleau, en millimètres (Paramètres).
export interface RollSize {
  widthMm: number;
  heightMm: number;
}

export const DEFAULT_ROLL: RollSize = { widthMm: 50, heightMm: 30 };

/// Pixels par barre élémentaire dans les images de `barcodePng` (`scale: 3`).
const PX_PER_MODULE = 3;

/// En dessous, une douchette ordinaire ne lit plus le code (barres trop fines).
export const MIN_MODULE_MM = 0.25;

/// Marge de l'étiquette et zone de silence de part et d'autre des barres (la
/// douchette a besoin de blanc avant la première barre).
const PAD = 1.5 * MM;
const QUIET = 1.5 * MM;

/// Largeur des barres : toute l'étiquette, moins marges et zones de silence.
function barsWidth(labelWidth: number): number {
  return labelWidth - 2 * (PAD + QUIET);
}

/// Barre la plus fine (mm) une fois les barres étirées sur leur largeur.
export function moduleWidthMm(
  png: Buffer,
  label: { width: number; height: number },
): number {
  // Largeur de l'image : en-tête IHDR du PNG ; une barre = PX_PER_MODULE px.
  const modules = png.readUInt32BE(16) / PX_PER_MODULE;
  return barsWidth(label.width) / modules / MM;
}

export async function renderLabels(
  labels: Label[],
  format: LabelFormat,
  roll: RollSize = DEFAULT_ROLL,
): Promise<Buffer> {
  const ROLL = { width: roll.widthMm * MM, height: roll.heightMm * MM };
  const size = format === 'A4' ? SHEET : ROLL;
  // Une image par code, même imprimé plusieurs fois.
  const images = new Map<string, Buffer>();
  for (const label of labels) {
    if (!images.has(label.barcode)) {
      images.set(label.barcode, await barcodePng(label.barcode));
    }
  }
  // Un code trop long pour la largeur de l'étiquette devient illisible : on le
  // dit, en nommant le produit, plutôt que d'imprimer une étiquette muette.
  const unreadable = labels.filter(
    (label, i, all) =>
      all.findIndex((l) => l.barcode === label.barcode) === i &&
      moduleWidthMm(images.get(label.barcode)!, size) < MIN_MODULE_MM,
  );
  if (unreadable.length > 0) {
    throw new BusinessException(
      ErrorCode.VALIDATION_FAILED,
      `Code-barres trop long pour être lu sur ${format === 'A4' ? 'la planche A4' : 'le rouleau'} : ` +
        unreadable
          .slice(0, 5)
          .map((l) => `${l.name} (${l.barcode})`)
          .join(', ') +
        (format === 'ROULEAU' ? ' — essayez la planche A4' : ''),
      HttpStatus.UNPROCESSABLE_ENTITY,
    );
  }
  const perSheet = SHEET.cols * SHEET.rows;
  return renderPdf(
    format === 'A4'
      ? { size: 'A4', margin: 0 }
      : { size: [ROLL.width, ROLL.height], margin: 0 },
    (doc) => {
      // Chaque image est OUVERTE une seule fois par document : pdfkit ne met
      // en cache que les images passées par un chemin, jamais un tampon — sans
      // cela, 1 000 étiquettes du même produit décodaient et embarquaient 1 000
      // fois la même image (~20 s de serveur bloqué, 23 Mo ; audit sécurité).
      const opened = new Map(
        [...images].map(([code, png]) => [code, openImage(doc, png)]),
      );
      labels.forEach((label, i) => {
        const image = opened.get(label.barcode)!;
        if (format === 'A4') {
          const slot = i % perSheet;
          if (i > 0 && slot === 0) doc.addPage({ size: 'A4', margin: 0 });
          drawLabel(
            doc,
            label,
            image,
            (slot % SHEET.cols) * SHEET.width,
            Math.floor(slot / SHEET.cols) * SHEET.height,
            SHEET.width,
            SHEET.height,
          );
        } else {
          if (i > 0) {
            doc.addPage({ size: [ROLL.width, ROLL.height], margin: 0 });
          }
          drawLabel(doc, label, image, 0, 0, ROLL.width, ROLL.height);
        }
      });
    },
  );
}

/// Une étiquette, mise en page selon SA taille (de 20 × 15 à 150 × 150 mm) :
/// nom (2 lignes au plus), prix en gros, référence, puis en bas le
/// code-barres sur toute la largeur et son code en clair, séparé des barres.
function drawLabel(
  doc: PdfDoc,
  label: Label,
  barcode: PDFKit.Mixins.ImageSrc,
  x: number,
  y: number,
  width: number,
  height: number,
) {
  const inner = width - 2 * PAD;
  const hMm = height / MM;
  const clamp = (v: number, lo: number, hi: number) =>
    Math.min(hi, Math.max(lo, v));
  const nameSize = clamp(hMm * 0.16, 5.5, 11);
  const skuSize = clamp(hMm * 0.1, 5, 7);
  const digitsSize = clamp(hMm * 0.12, 6.5, 11);
  let cy = y + PAD;

  // Nom sur deux lignes au plus : la suite est coupée, jamais débordante.
  doc.font('Helvetica-Bold').fontSize(nameSize);
  const nameH = Math.min(
    doc.heightOfString(label.name, { width: inner }),
    nameSize * 2.4,
  );
  doc.text(label.name, x + PAD, cy, {
    width: inner,
    height: nameH,
    ellipsis: true,
  });
  cy += nameH + 1;

  // Prix : le plus gros possible SANS déborder (jamais d'ellipse sur un prix).
  const unit = UNIT_LABEL[label.unit];
  const price =
    formatDA(label.priceTtc) +
    (unit && label.unit !== 'PIECE' ? ` / ${unit}` : '');
  let priceSize = clamp(hMm * 0.26, 8, 24);
  doc.font('Helvetica-Bold');
  while (
    priceSize > 6 &&
    doc.fontSize(priceSize).widthOfString(price) > inner
  ) {
    priceSize -= 0.5;
  }
  doc.text(price, x + PAD, cy, { width: inner, lineBreak: false });
  cy += priceSize * 1.05;
  doc
    .font('Helvetica')
    .fontSize(skuSize)
    .text(label.sku, x + PAD, cy, {
      width: inner,
      lineBreak: false,
      ellipsis: true,
    });
  cy += skuSize * 1.3 + 0.8 * MM;

  // En bas : le code en clair, puis au-dessus — séparées par un vrai blanc —
  // les barres, étirées sur toute la largeur utile.
  const digitsY = y + height - PAD - digitsSize * 1.1;
  const barsBottom = digitsY - 1.2 * MM;
  const barsH = Math.max(barsBottom - cy, 3 * MM);
  doc.image(barcode, x + PAD + QUIET, barsBottom - barsH, {
    width: barsWidth(width),
    height: barsH,
  });
  doc
    .font('Helvetica')
    .fontSize(digitsSize)
    .text(label.barcode, x + PAD, digitsY, {
      width: inner,
      align: 'center',
      lineBreak: false,
      characterSpacing: digitsSize * 0.18,
    });
}
