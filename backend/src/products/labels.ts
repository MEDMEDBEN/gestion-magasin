import { HttpStatus } from '@nestjs/common';
import { barcodePng } from '../common/barcode/barcode';
import { BusinessException } from '../common/business.exception';
import { ErrorCode } from '../common/error-codes';
import { taxAmount } from '../common/money';
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

/// Étiquette d'un produit au prix HT de son tarif : TTC calculé EXACTEMENT
/// comme la ligne de vente (`taxAmount`) — le prix lu en rayon est le prix payé.
export function labelFor(
  product: {
    name: string;
    sku: string;
    barcode: string;
    unit: string;
    taxRate: { rate: Parameters<typeof taxAmount>[1] } | null;
  },
  priceHt: number,
): Label {
  return {
    name: product.name,
    sku: product.sku,
    barcode: product.barcode,
    priceTtc: priceHt + taxAmount(priceHt, product.taxRate?.rate ?? 0),
    unit: product.unit,
  };
}

const MM = 72 / 25.4;

/// Planche « 24 étiquettes » 70 × 37 mm sans marge, la plus courante en
/// papeterie. ponytail: un seul gabarit A4 et un seul rouleau (50 × 30 mm) ;
/// ajouter un réglage le jour où le magasin achète un autre format.
const SHEET = { cols: 3, rows: 8, width: 70 * MM, height: 37.125 * MM };
const ROLL = { width: 50 * MM, height: 30 * MM };

/// Pixels par barre élémentaire dans les images de `barcodePng` (`scale: 3`).
const PX_PER_MODULE = 3;

/// En dessous, une douchette ordinaire ne lit plus le code (barres trop fines).
export const MIN_MODULE_MM = 0.25;

/// Zone du code-barres dans une étiquette, et barre la plus fine qu'il y aura
/// une fois l'image réduite pour y tenir.
function barcodeBox(width: number, height: number) {
  const pad = 2.5 * MM;
  return { width: width - 2 * pad, height: height * 0.42 - pad };
}

export function moduleWidthMm(
  png: Buffer,
  label: { width: number; height: number },
): number {
  // Largeur et hauteur de l'image : en-tête IHDR du PNG.
  const w = png.readUInt32BE(16);
  const h = png.readUInt32BE(20);
  const box = barcodeBox(label.width, label.height);
  const scale = Math.min(box.width / w, box.height / h, 1 / PX_PER_MODULE);
  return (scale * PX_PER_MODULE) / MM;
}

export async function renderLabels(
  labels: Label[],
  format: LabelFormat,
): Promise<Buffer> {
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

function drawLabel(
  doc: PdfDoc,
  label: Label,
  barcode: PDFKit.Mixins.ImageSrc,
  x: number,
  y: number,
  width: number,
  height: number,
) {
  const pad = 2.5 * MM;
  const inner = width - 2 * pad;
  // Nom sur deux lignes au plus : la suite est coupée, jamais débordante.
  doc
    .font('Helvetica-Bold')
    .fontSize(height > 35 * MM ? 8 : 6.5)
    .text(label.name, x + pad, y + pad, {
      width: inner,
      height: height * 0.24,
      ellipsis: true,
    });
  const unit = UNIT_LABEL[label.unit];
  const price =
    formatDA(label.priceTtc) +
    (unit && label.unit !== 'PIECE' ? ` / ${unit}` : '');
  doc
    .font('Helvetica-Bold')
    .fontSize(height > 35 * MM ? 13 : 10)
    // Jamais d'ellipse sur un prix : « 1 234 5… » serait pire qu'un débord.
    .text(price, x + pad, y + height * 0.3, {
      width: inner,
      lineBreak: false,
    });
  doc
    .font('Helvetica')
    .fontSize(5.5)
    .text(label.sku, x + pad, y + height * 0.3 + (height > 35 * MM ? 15 : 12), {
      width: inner,
      lineBreak: false,
      ellipsis: true,
    });
  // Code-barres dans le bas de l'étiquette, à sa taille maximale.
  const box = barcodeBox(width, height);
  doc.image(barcode, x + pad, y + height * 0.55, {
    fit: [box.width, box.height],
    align: 'center',
    valign: 'bottom',
  });
}
