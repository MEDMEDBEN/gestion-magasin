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
/// unique. UN seul support (décision MEDMEDBEN du 2026-11-13) : l'étiquette
/// 35 × 45 mm en PORTRAIT de l'imprimante d'étiquettes, partout (poste, web).

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

/// L'étiquette du magasin : 35 mm de large, 45 mm de haut (portrait).
export const LABEL = { width: 35 * MM, height: 45 * MM };

/// Pixels par barre élémentaire dans les images de `barcodePng` (`scale: 6`).
const PX_PER_MODULE = 6;

/// En dessous, une douchette ordinaire ne lit plus le code (barres trop fines).
export const MIN_MODULE_MM = 0.25;

/// Marge de l'étiquette et zone de silence de part et d'autre des barres (la
/// douchette a besoin de blanc avant la première barre).
/// Marge de 2,5 mm : TOUT le contenu tient dans 30 × 40 mm au centre de
/// l'étiquette (demande MEDMEDBEN du 2026-11-13), à l'abri d'un décalage.
const PAD = 2.5 * MM;

/// Largeur des barres : toute la zone de 30 mm ; la marge blanche de 2,5 mm
/// de chaque côté sert de zone de silence à la douchette.
function barsWidth(labelWidth: number): number {
  return labelWidth - 2 * PAD;
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

export async function renderLabels(labels: Label[]): Promise<Buffer> {
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
      moduleWidthMm(images.get(label.barcode)!, LABEL) < MIN_MODULE_MM,
  );
  if (unreadable.length > 0) {
    throw new BusinessException(
      ErrorCode.VALIDATION_FAILED,
      'Code-barres trop long pour être lu sur l’étiquette 35 × 45 mm : ' +
        unreadable
          .slice(0, 5)
          .map((l) => `${l.name} (${l.barcode})`)
          .join(', '),
      HttpStatus.UNPROCESSABLE_ENTITY,
    );
  }
  const page = { size: [LABEL.width, LABEL.height], margin: 0 };
  return renderPdf(page, (doc) => {
    // Chaque image est OUVERTE une seule fois par document : pdfkit ne met
    // en cache que les images passées par un chemin, jamais un tampon — sans
    // cela, 1 000 étiquettes du même produit décodaient et embarquaient 1 000
    // fois la même image (~20 s de serveur bloqué, 23 Mo ; audit sécurité).
    const opened = new Map(
      [...images].map(([code, png]) => [code, openImage(doc, png)]),
    );
    labels.forEach((label, i) => {
      if (i > 0) doc.addPage(page);
      drawLabel(doc, label, opened.get(label.barcode)!);
    });
  });
}

/// Une étiquette 35 × 45 : en haut le NOM (2 lignes au plus) puis le PRIX en
/// gros, centrés ; dessous, le code-barres sur toute la largeur utile, grand
/// et centré, et son code en clair.
function drawLabel(doc: PdfDoc, label: Label, barcode: PDFKit.Mixins.ImageSrc) {
  const { width, height } = LABEL;
  const inner = width - 2 * PAD;
  // +0,3 mm : les accents des majuscules (Â, É) restent dans la zone.
  let cy = PAD + 0.3 * MM;

  // Nom : deux lignes au plus, la suite coupée, jamais débordante.
  const nameSize = 8.5;
  doc.font('Helvetica-Bold').fontSize(nameSize);
  const nameH = Math.min(
    doc.heightOfString(label.name, { width: inner, align: 'center' }),
    nameSize * 2.5,
  );
  doc.text(label.name, PAD, cy, {
    width: inner,
    height: nameH,
    align: 'center',
    ellipsis: true,
  });
  cy += nameH + 0.6 * MM;

  // Prix : le plus gros possible SANS déborder (jamais d'ellipse sur un prix).
  const unit = UNIT_LABEL[label.unit];
  const price =
    formatDA(label.priceTtc) +
    (unit && label.unit !== 'PIECE' ? ` / ${unit}` : '');
  let priceSize = 17;
  doc.font('Helvetica-Bold');
  while (
    priceSize > 7 &&
    doc.fontSize(priceSize).widthOfString(price) > inner
  ) {
    priceSize -= 0.5;
  }
  doc.text(price, PAD, cy, { width: inner, align: 'center', lineBreak: false });
  cy += priceSize * 1.05 + 1 * MM;

  // Code en clair tout en bas ; les barres remplissent l'espace entre le prix
  // et lui, sur toute la largeur (zones de silence comprises), centrées.
  const digitsSize = 8;
  const digitsY = height - PAD - digitsSize;
  const barsBottom = digitsY - 0.8 * MM;
  const barsW = barsWidth(width);
  const barsH = Math.max(barsBottom - cy, 8 * MM);
  doc.image(barcode, (width - barsW) / 2, barsBottom - barsH, {
    width: barsW,
    height: barsH,
  });
  doc.font('Helvetica').fontSize(digitsSize).text(label.barcode, PAD, digitsY, {
    width: inner,
    align: 'center',
    lineBreak: false,
    characterSpacing: 0.8,
  });
}
