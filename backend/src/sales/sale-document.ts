import { HttpStatus } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { BusinessException } from '../common/business.exception';
import { ErrorCode } from '../common/error-codes';
import {
  formatDA,
  formatDateTime,
  PdfDoc,
  renderPdf,
  UNIT_LABEL,
} from '../common/pdf/pdf';
import { Prisma } from '../generated/prisma/client';
import { SaleDto } from './dto/sale.dto';

/// Identité du vendeur imprimée en tête (variables STORE_* ; vides = omises).
export interface StoreIdentity {
  name: string;
  address?: string;
  phone?: string;
  /// Mentions légales (NIF, RC, NIS, AI) déjà mises en forme, une par entrée.
  legal: string[];
}

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

/// Identité du magasin imprimée en tête des documents (variables STORE_*).
/// `requireLegal` : une facture exige ses mentions légales ; un ticket, un devis
/// ou un bon de commande reste imprimable sans.
export function storeIdentity(
  config: ConfigService,
  requireLegal: boolean,
): StoreIdentity {
  const env = (key: string) => config.get<string>(key)?.trim() || undefined;
  if (requireLegal && !(env('STORE_NIF') && env('STORE_RC'))) {
    throw new BusinessException(
      ErrorCode.STORE_IDENTITY_MISSING,
      'Mentions légales du magasin absentes (STORE_NIF, STORE_RC) : facture non imprimable',
      HttpStatus.UNPROCESSABLE_ENTITY,
    );
  }
  const legal = (['NIF', 'RC', 'NIS', 'AI'] as const).flatMap((key) => {
    const value = env(`STORE_${key}`);
    return value ? [`${key} : ${value}`] : [];
  });
  return {
    name: env('STORE_NAME') ?? 'Magasin',
    address: env('STORE_ADDRESS'),
    phone: env('STORE_PHONE'),
    legal,
  };
}

/// Facture (numéro légal attribué) → A4 ; sinon ticket de caisse 80 mm.
export function renderSaleDocument(data: SaleDocumentData): Promise<Buffer> {
  return data.sale.invoiceNumber ? renderInvoice(data) : renderTicket(data);
}

/// Mention en rouge, centrée (vente annulée, devis refusé…).
function stamp(doc: PdfDoc, text: string, x: number, width: number) {
  doc
    .moveDown(0.5)
    .font('Helvetica-Bold')
    .fillColor('#b00020')
    .text(text, x, doc.y, { width, align: 'center' })
    .fillColor('black');
}

const TICKET_WIDTH = 226.77; // 80 mm
const TICKET_MARGIN = 10;

function renderTicket(data: SaleDocumentData): Promise<Buffer> {
  const { sale, store } = data;
  // Hauteur du rouleau : ~38 caractères par ligne de désignation à 80 mm.
  const nameLines = sale.lines.reduce(
    (n, l) =>
      n +
      Math.max(
        1,
        Math.ceil(designation(data.products, l.productId).name.length / 38),
      ),
    0,
  );
  const height =
    240 + sale.lines.length * 34 + nameLines * 11 + store.legal.length * 10;
  return renderPdf(
    {
      size: [TICKET_WIDTH, height],
      margin: TICKET_MARGIN,
      info: { Title: `Ticket ${sale.number}` },
    },
    (doc) => {
      const w = TICKET_WIDTH - 2 * TICKET_MARGIN;
      const x = TICKET_MARGIN;
      const row = (left: string, right: string, bold = false) => {
        const y = doc.y;
        doc.font(bold ? 'Helvetica-Bold' : 'Helvetica');
        doc.text(left, x, y, { width: w * 0.55 });
        const after = doc.y;
        doc.text(right, x, y, { width: w, align: 'right' });
        doc.y = Math.max(after, doc.y);
      };
      const rule = () => {
        doc.moveDown(0.3);
        doc
          .moveTo(x, doc.y)
          .lineTo(x + w, doc.y)
          .dash(2, { space: 2 })
          .stroke()
          .undash();
        doc.moveDown(0.3);
      };

      doc.font('Helvetica-Bold').fontSize(11);
      doc.text(store.name, x, doc.y, { width: w, align: 'center' });
      doc.font('Helvetica').fontSize(7.5);
      for (const line of [store.address, store.phone, ...store.legal]) {
        if (line) doc.text(line, { width: w, align: 'center' });
      }
      rule();
      doc.fontSize(8);
      row(`Ticket ${sale.number}`, formatDateTime(new Date(sale.soldAt)), true);
      doc.font('Helvetica').text(`Vendeur : ${data.sellerName}`, x, doc.y, {
        width: w,
      });
      if (data.customer)
        doc.text(`Client : ${data.customer.name}`, { width: w });
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
          row('  dont remise HT', `-${formatDA(line.discountAmount)}`);
        }
      }
      rule();
      row('Total HT', formatDA(sale.totalHt));
      row('TVA', formatDA(sale.totalTax));
      doc.fontSize(10);
      row('TOTAL TTC', formatDA(sale.totalTtc), true);
      doc.fontSize(8);
      row('Payé (espèces)', formatDA(sale.paidAmount));
      if (sale.remainingAmount > 0) {
        row('Reste dû (crédit)', formatDA(sale.remainingAmount), true);
      }
      if (sale.status === 'ANNULEE') stamp(doc, 'VENTE ANNULÉE', x, w);
      rule();
      doc
        .font('Helvetica')
        .fontSize(7.5)
        .text('Merci de votre visite', x, doc.y, { width: w, align: 'center' });
    },
  );
}

const A4_MARGIN = 40;

function renderInvoice(data: SaleDocumentData): Promise<Buffer> {
  const { sale } = data;
  return renderA4Document({
    title: 'FACTURE',
    pdfTitle: `Facture ${sale.invoiceNumber}`,
    info: [
      `N° ${sale.invoiceNumber}`,
      `Date : ${formatDateTime(new Date(sale.invoicedAt ?? sale.soldAt))}`,
      `Ticket ${sale.number} du ${formatDateTime(new Date(sale.soldAt))}`,
    ],
    store: data.store,
    customer: data.customer,
    products: data.products,
    lines: sale.lines,
    totalHt: sale.totalHt,
    totalTtc: sale.totalTtc,
    after: [
      ['Payé (espèces)', formatDA(sale.paidAmount)],
      ['Reste à payer', formatDA(sale.remainingAmount)],
    ],
    stamp: sale.status === 'ANNULEE' ? 'VENTE ANNULÉE' : undefined,
    footer: `Vendeur : ${data.sellerName}`,
  });
}

/// Document commercial A4 (facture, devis) : UN gabarit, pour que les deux
/// documents remis au client aient la même tête, la même table et la même
/// ventilation de TVA.
export interface A4Document {
  /// En gros, en haut à droite : « FACTURE », « DEVIS ».
  title: string;
  pdfTitle: string;
  /// Lignes sous le titre : numéro, dates.
  info: string[];
  store: StoreIdentity;
  /// En tête du bloc de la partie : « Client » (défaut), « Fournisseur ».
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
  }[];
  totalHt: number;
  totalTtc: number;
  /// Montants imprimés sous le Total TTC (payé, reste…).
  after: [string, string][];
  /// Mention en rouge sous les totaux (annulation).
  stamp?: string;
  footer: string;
}

export function renderA4Document(input: A4Document): Promise<Buffer> {
  const { store } = input;
  return renderPdf(
    {
      size: 'A4',
      margin: A4_MARGIN,
      info: { Title: input.pdfTitle },
    },
    (doc) => {
      const left = A4_MARGIN;
      const w = doc.page.width - 2 * A4_MARGIN;

      // En-tête : vendeur à gauche, titre, n° et dates à droite.
      const top = doc.y;
      doc
        .font('Helvetica-Bold')
        .fontSize(14)
        .text(store.name, left, top, {
          width: w / 2,
        });
      doc.font('Helvetica').fontSize(9);
      for (const line of [store.address, store.phone, ...store.legal]) {
        if (line) doc.text(line, { width: w / 2 });
      }
      const leftBottom = doc.y;
      doc
        .font('Helvetica-Bold')
        .fontSize(16)
        .text(input.title, left + w / 2, top, { width: w / 2, align: 'right' });
      doc.font('Helvetica').fontSize(10);
      for (const line of input.info) {
        doc.text(line, { width: w / 2, align: 'right' });
      }
      doc.y = Math.max(leftBottom, doc.y) + 20;

      // Client (facture, devis) ou fournisseur (bon de commande)
      const party = input.partyLabel ?? 'Client';
      doc.font('Helvetica-Bold').fontSize(10).text(party, left, doc.y);
      doc.font('Helvetica').fontSize(9);
      if (input.customer) {
        doc.text(input.customer.name);
        if (input.customer.address) doc.text(input.customer.address);
        if (input.customer.phone) doc.text(input.customer.phone);
      } else {
        doc.text(`${party} comptoir`);
      }
      doc.moveDown(1.5);

      // Lignes
      const cols = [
        { title: 'Désignation', width: w * 0.4, align: 'left' as const },
        { title: 'Qté', width: w * 0.1, align: 'right' as const },
        { title: 'PU HT', width: w * 0.16, align: 'right' as const },
        { title: 'TVA', width: w * 0.1, align: 'right' as const },
        { title: 'Total HT', width: w * 0.24, align: 'right' as const },
      ];
      const tableRow = (cells: string[], bold = false) => {
        if (doc.y > doc.page.height - A4_MARGIN - 120) doc.addPage();
        const y = doc.y;
        let x = left;
        let bottom = y;
        doc.font(bold ? 'Helvetica-Bold' : 'Helvetica').fontSize(9);
        cells.forEach((cell, i) => {
          doc.text(cell, x + 2, y, {
            width: cols[i].width - 4,
            align: cols[i].align,
          });
          bottom = Math.max(bottom, doc.y);
          x += cols[i].width;
        });
        doc.y = bottom + 4;
        doc
          .moveTo(left, doc.y - 2)
          .lineTo(left + w, doc.y - 2)
          .strokeColor('#cccccc')
          .stroke()
          .strokeColor('black');
      };
      tableRow(
        cols.map((c) => c.title),
        true,
      );
      for (const line of input.lines) {
        const d = designation(input.products, line.productId);
        tableRow([
          d.sku ? `${d.name}\n${d.sku}` : d.name,
          `${qty(line.quantity)} ${d.unit}`,
          formatDA(line.unitPriceHt),
          `${qty(line.taxRate)} %`,
          formatDA(line.lineTotalHt),
        ]);
      }

      // Totaux (TVA ventilée par taux)
      doc.moveDown(1);
      const byRate = new Map<string, number>();
      for (const line of input.lines) {
        byRate.set(
          line.taxRate,
          (byRate.get(line.taxRate) ?? 0) + line.lineTaxAmount,
        );
      }
      const totalsX = left + w * 0.5;
      const total = (label: string, amount: string, bold = false) => {
        const y = doc.y;
        doc
          .font(bold ? 'Helvetica-Bold' : 'Helvetica')
          .fontSize(bold ? 11 : 9.5);
        doc.text(label, totalsX, y, { width: w * 0.25 });
        doc.text(amount, totalsX, y, { width: w * 0.5, align: 'right' });
        doc.moveDown(0.2);
      };
      total('Total HT', formatDA(input.totalHt));
      for (const [rate, amount] of byRate) {
        total(`TVA ${qty(rate)} %`, formatDA(amount));
      }
      total('Total TTC', formatDA(input.totalTtc), true);
      if (input.after.length > 0) doc.moveDown(0.5);
      for (const [label, amount] of input.after) total(label, amount);
      if (input.stamp) stamp(doc, input.stamp, left, w);
      doc
        .font('Helvetica')
        .fontSize(8)
        .text(input.footer, left, doc.y + 20, { width: w });
    },
  );
}
