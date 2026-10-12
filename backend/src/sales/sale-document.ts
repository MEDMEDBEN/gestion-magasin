import {
  BusinessDocument,
  DocumentColumn,
  renderBusinessDocument,
} from '../common/pdf/business-document';
import {
  formatDA,
  formatDateTime,
  PdfDoc,
  renderPdf,
  UNIT_LABEL,
} from '../common/pdf/pdf';
import { Prisma } from '../generated/prisma/client';
import { DocumentPaper, StoreIdentity } from '../settings/store-settings';
import { SaleDto } from './dto/sale.dto';

export interface SaleDocumentData {
  sale: SaleDto;
  store: StoreIdentity;
  sellerName: string;
  customer: {
    name: string;
    address: string | null;
    phone: string | null;
  } | null;
  /// productId → désignation et unité
  products: Map<string, { name: string; sku: string; unit: string }>;
}

/// « 2.500 » → « 2,5 »
function qty(value: string): string {
  return value.replace(/\.?0+$/, '').replace('.', ',');
}

function designation(
  products: SaleDocumentData['products'],
  productId: string,
) {
  const p = products.get(productId);
  return {
    name: p?.name ?? productId,
    sku: p?.sku ?? '',
    unit: UNIT_LABEL[p?.unit ?? ''] ?? '',
  };
}

/// Facture (numéro légal attribué) → document A4/A5 ; sinon le ticket, au
/// format choisi dans Paramètres : rouleau 80 ou 58 mm, ou bon de vente A5/A4
/// pour qui imprime ses tickets sur une imprimante de bureau.
export function renderSaleDocument(data: SaleDocumentData): Promise<Buffer> {
  if (data.sale.invoiceNumber) return renderInvoice(data);
  const paper = data.store.ticketPaper ?? 'TICKET_80';
  if (paper === 'A4' || paper === 'A5') return renderSaleSlip(data, paper);
  return renderTicket(data, paper === 'TICKET_58' ? 58 : 80);
}

/// Mention en rouge, centrée (vente annulée…).
function stamp(doc: PdfDoc, text: string, x: number, width: number) {
  doc
    .moveDown(0.5)
    .font('Helvetica-Bold')
    .fillColor('#b00020')
    .text(text, x, doc.y, { width, align: 'center' })
    .fillColor('black');
}

const MM = 72 / 25.4;

/// Ticket de caisse en rouleau thermique (80 ou 58 mm de large).
async function renderTicket(
  data: SaleDocumentData,
  mm: 58 | 80,
): Promise<Buffer> {
  const { sale, store } = data;
  const narrow = mm === 58;
  const width = mm * MM;
  const margin = narrow ? 6 : 10;
  const k = narrow ? 0.85 : 1;
  const draw = (doc: PdfDoc) => {
    const w = width - 2 * margin;
    const x = margin;
    const row = (left: string, right: string, bold = false) => {
      const y = doc.y;
      doc.font(bold ? 'Helvetica-Bold' : 'Helvetica');
      doc.text(left, x, y, { width: w * 0.55 });
      const after = doc.y;
      doc.text(right, x, y, { width: w, align: 'right' });
      doc.y = Math.max(after, doc.y);
    };
    const rule = (strong = false) => {
      doc.moveDown(0.3);
      doc.moveTo(x, doc.y).lineTo(x + w, doc.y);
      if (strong) doc.lineWidth(1.2).stroke().lineWidth(1);
      else doc.dash(2, { space: 2 }).stroke().undash();
      doc.moveDown(0.3);
    };

    doc.font('Helvetica-Bold').fontSize(12 * k);
    doc.text(store.name.toUpperCase(), x, doc.y, {
      width: w,
      align: 'center',
    });
    doc.font('Helvetica').fontSize(7.5 * k);
    for (const line of [
      store.address,
      store.phone ? `Tél : ${store.phone}` : undefined,
      ...store.legal,
    ]) {
      if (line) doc.text(line, { width: w, align: 'center' });
    }
    rule(true);
    doc.fontSize(8 * k);
    row(`Ticket ${sale.number}`, formatDateTime(new Date(sale.soldAt)), true);
    doc.font('Helvetica').text(`Vendeur : ${data.sellerName}`, x, doc.y, {
      width: w,
    });
    if (data.customer) doc.text(`Client : ${data.customer.name}`, { width: w });
    rule();

    for (const line of sale.lines) {
      const d = designation(data.products, line.productId);
      doc.font('Helvetica-Bold').text(d.name, x, doc.y, { width: w });
      // Prix unitaire TTC affiché (le total de ligne, lui, vient du serveur).
      const unitTtc = new Prisma.Decimal(line.unitPriceHt)
        .mul(new Prisma.Decimal(line.taxRate).add(100))
        .div(100)
        .toDecimalPlaces(0, Prisma.Decimal.ROUND_HALF_UP)
        .toNumber();
      row(
        `${qty(line.quantity)} ${d.unit} × ${formatDA(unitTtc)}`,
        formatDA(line.lineTotalTtc),
      );
      if (line.discountAmount > 0) {
        row('  dont remise', `-${formatDA(line.discountAmount)}`);
      }
    }
    rule(true);
    // Sans TVA (retirée le 2026-10-05) : un seul total. Un ticket d'avant
    // garde sa ventilation HT / TVA / TTC.
    const taxed = sale.totalTax > 0;
    if (taxed) {
      row('Total HT', formatDA(sale.totalHt));
      row('TVA', formatDA(sale.totalTax));
    }
    if (sale.discountAmount > 0) {
      row('Remise sur facture', `-${formatDA(sale.discountAmount)}`);
    }
    doc.fontSize(11 * k);
    row(taxed ? 'TOTAL TTC' : 'TOTAL', formatDA(sale.totalTtc), true);
    doc.fontSize(8 * k);
    row('Payé (espèces)', formatDA(sale.paidAmount));
    if (sale.remainingAmount > 0) {
      row('Reste dû (crédit)', formatDA(sale.remainingAmount), true);
    }
    if (sale.status === 'ANNULEE') stamp(doc, 'VENTE ANNULÉE', x, w);
    rule();
    doc
      .font('Helvetica')
      .fontSize(7.5 * k)
      .text(store.footer ?? 'Merci de votre visite', x, doc.y, {
        width: w,
        align: 'center',
      });
  };
  // Hauteur EXACTE du rouleau : un premier rendu mesure où s'arrête le
  // ticket, le second coupe juste après — pas de papier perdu, jamais coupé.
  let end = 0;
  await renderPdf({ size: [width, 200_000], margin }, (doc) => {
    draw(doc);
    end = doc.y;
  });
  return renderPdf(
    {
      size: [width, Math.ceil(end + margin + 4)],
      margin,
      info: { Title: `Ticket ${sale.number}` },
    },
    draw,
  );
}

/// Ticket imprimé sur une imprimante de bureau : un BON DE VENTE A5/A4.
function renderSaleSlip(
  data: SaleDocumentData,
  paper: DocumentPaper,
): Promise<Buffer> {
  const { sale } = data;
  return renderA4Document({
    title: 'BON DE VENTE',
    pdfTitle: `Bon de vente ${sale.number}`,
    number: sale.number,
    meta: [
      ['Date', formatDateTime(new Date(sale.soldAt))],
      ['Vendeur', data.sellerName],
    ],
    store: data.store,
    customer: data.customer,
    products: data.products,
    lines: sale.lines,
    totalHt: sale.totalHt,
    totalTtc: sale.totalTtc,
    discount: sale.discountAmount,
    after: [
      ['Payé (espèces)', formatDA(sale.paidAmount)],
      ...(sale.remainingAmount > 0
        ? ([['Reste à payer', formatDA(sale.remainingAmount)]] as [
            string,
            string,
          ][])
        : []),
    ],
    stamp: sale.status === 'ANNULEE' ? 'VENTE ANNULÉE' : undefined,
    signatures: ['Le client', 'Le vendeur'],
    paper,
  });
}

function renderInvoice(data: SaleDocumentData): Promise<Buffer> {
  const { sale } = data;
  return renderA4Document({
    title: 'FACTURE',
    pdfTitle: `Facture ${sale.invoiceNumber}`,
    number: sale.invoiceNumber!,
    meta: [
      ['Date', formatDateTime(new Date(sale.invoicedAt ?? sale.soldAt))],
      ['Ticket', sale.number],
      ['Vendeur', data.sellerName],
    ],
    store: data.store,
    customer: data.customer,
    products: data.products,
    lines: sale.lines,
    totalHt: sale.totalHt,
    totalTtc: sale.totalTtc,
    discount: sale.discountAmount,
    after: [
      ['Payé (espèces)', formatDA(sale.paidAmount)],
      ['Reste à payer', formatDA(sale.remainingAmount)],
    ],
    stamp: sale.status === 'ANNULEE' ? 'VENTE ANNULÉE' : undefined,
    wordsSubject: 'la présente facture',
    signatures: ['Le client', 'Cachet et signature du vendeur'],
  });
}

/// Document commercial avec lignes de produits (facture, devis, bons de
/// commande et de retour) : un seul gabarit, rendu par le document industriel
/// commun (`renderBusinessDocument`), au format des Paramètres.
export interface A4Document {
  /// Titre du cartouche : « FACTURE », « DEVIS »…
  title: string;
  pdfTitle: string;
  number: string;
  /// Références du cartouche : [« Date », « … »]…
  meta: [string, string][];
  store: StoreIdentity;
  /// En tête de l'encadré de la partie : « Client » (défaut), « Fournisseur ».
  partyLabel?: string;
  customer: SaleDocumentData['customer'];
  products: SaleDocumentData['products'];
  lines: {
    productId: string;
    quantity: string;
    unitPriceHt: number;
    taxRate: string;
    lineTotalHt: number;
    lineTaxAmount: number;
    discountAmount?: number;
  }[];
  totalHt: number;
  totalTtc: number;
  /// Remise sur toute la facture (déjà comprise dans les lignes).
  discount?: number;
  /// Montants imprimés sous le total (payé, reste…).
  after: [string, string][];
  /// Mention en rouge (annulation).
  stamp?: string;
  /// Ligne d'information sous les totaux (« Établi par… », motif…).
  footer?: string;
  /// « Arrêté … à la somme de » ; défaut : « le présent document ».
  wordsSubject?: string;
  signatures?: string[];
  /// Format imposé (bon de vente) ; défaut : celui des Paramètres.
  paper?: DocumentPaper;
}

export function renderA4Document(input: A4Document): Promise<Buffer> {
  // Sans TVA sur aucune ligne (retirée le 2026-10-05) : ni colonne TVA, ni
  // « HT » ; un document d'avant garde la sienne.
  const taxed = input.lines.some((l) => Number(l.taxRate) !== 0);
  const discounted = input.lines.some((l) => (l.discountAmount ?? 0) > 0);
  const columns: DocumentColumn[] = [
    { header: 'Référence', width: 2 },
    { header: 'Désignation', width: 6 },
    { header: 'Qté', width: 1.6, align: 'right' },
    { header: taxed ? 'PU HT' : 'Prix unitaire', width: 2.2, align: 'right' },
    ...(discounted
      ? [{ header: 'Remise', width: 1.8, align: 'right' as const }]
      : []),
    ...(taxed ? [{ header: 'TVA', width: 1.2, align: 'right' as const }] : []),
    { header: taxed ? 'Total HT' : 'Montant', width: 2.4, align: 'right' },
  ];
  const rows = input.lines.map((line) => {
    const d = designation(input.products, line.productId);
    return [
      d.sku,
      d.name,
      `${qty(line.quantity)} ${d.unit}`,
      formatDA(line.unitPriceHt),
      ...(discounted
        ? [line.discountAmount ? `-${formatDA(line.discountAmount)}` : '']
        : []),
      ...(taxed ? [`${qty(line.taxRate)} %`] : []),
      formatDA(line.lineTotalHt),
    ];
  });

  const totals: [string, string, boolean?][] = [];
  if (taxed) {
    const byRate = new Map<string, number>();
    for (const line of input.lines) {
      byRate.set(
        line.taxRate,
        (byRate.get(line.taxRate) ?? 0) + line.lineTaxAmount,
      );
    }
    totals.push(['Total HT', formatDA(input.totalHt)]);
    for (const [rate, amount] of byRate) {
      totals.push([`TVA ${qty(rate)} %`, formatDA(amount)]);
    }
  }
  if (input.discount) {
    // Déjà RÉPARTIE dans les lignes : dite, pas soustraite une 2e fois.
    totals.push(['Remise sur facture (incluse)', formatDA(input.discount)]);
  }
  totals.push([
    taxed ? 'TOTAL TTC' : 'TOTAL À PAYER',
    formatDA(input.totalTtc),
    true,
  ]);
  for (const [label, amount] of input.after) totals.push([label, amount]);

  const party = input.partyLabel ?? 'Client';
  const document: BusinessDocument = {
    title: input.title,
    pdfTitle: input.pdfTitle,
    number: input.number,
    meta: input.meta,
    store: input.store,
    parties: [
      input.customer
        ? {
            label: party,
            name: input.customer.name,
            lines: [input.customer.address, input.customer.phone].filter(
              (l): l is string => !!l,
            ),
          }
        : { label: party, name: `${party} de passage`, lines: [] },
    ],
    columns,
    rows,
    totals,
    amountInWords: input.totalTtc,
    wordsSubject: input.wordsSubject,
    notes: input.footer ? [input.footer] : [],
    signatures: input.signatures,
    stamp: input.stamp,
    paper: input.paper ?? input.store.documentPaper ?? 'A4',
  };
  return renderBusinessDocument(document);
}
