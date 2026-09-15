import { formatDA, formatDateTime, PdfDoc, renderPdf } from '../common/pdf/pdf';
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

const UNIT_LABEL: Record<string, string> = {
  PIECE: 'pce',
  METRE: 'm',
  ROULEAU: 'rlx',
  BOITE: 'bte',
  PAQUET: 'pqt',
  KILOGRAMME: 'kg',
};

/// « 2.500 » → « 2,5 »
function qty(value: string): string {
  return value.replace(/\.?0+$/, '').replace('.', ',');
}

function designation(data: SaleDocumentData, productId: string) {
  const p = data.products.get(productId);
  return {
    name: p?.name ?? productId,
    sku: p?.sku ?? '',
    unit: UNIT_LABEL[p?.unit ?? ''] ?? '',
  };
}

/// Facture (numéro légal attribué) → A4 ; sinon ticket de caisse 80 mm.
export function renderSaleDocument(data: SaleDocumentData): Promise<Buffer> {
  return data.sale.invoiceNumber ? renderInvoice(data) : renderTicket(data);
}

function stampCancelled(doc: PdfDoc, sale: SaleDto, x: number, width: number) {
  if (sale.status !== 'ANNULEE') return;
  doc
    .moveDown(0.5)
    .font('Helvetica-Bold')
    .fillColor('#b00020')
    .text('VENTE ANNULÉE', x, doc.y, { width, align: 'center' })
    .fillColor('black');
}

const TICKET_WIDTH = 226.77; // 80 mm
const TICKET_MARGIN = 10;

function renderTicket(data: SaleDocumentData): Promise<Buffer> {
  const { sale, store } = data;
  const height = 240 + sale.lines.length * 34 + store.legal.length * 10;
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
        const d = designation(data, line.productId);
        doc.font('Helvetica-Bold').text(d.name, x, doc.y, { width: w });
        // Prix unitaire TTC affiché (le total de ligne, lui, vient du serveur).
        const unitTtc = Math.round(
          (line.unitPriceHt * (100 + Number(line.taxRate))) / 100,
        );
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
      stampCancelled(doc, sale, x, w);
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
  const { sale, store } = data;
  return renderPdf(
    {
      size: 'A4',
      margin: A4_MARGIN,
      info: { Title: `Facture ${sale.invoiceNumber}` },
    },
    (doc) => {
      const left = A4_MARGIN;
      const w = doc.page.width - 2 * A4_MARGIN;

      // En-tête : vendeur à gauche, n° et date à droite.
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
        .text('FACTURE', left + w / 2, top, { width: w / 2, align: 'right' });
      doc.font('Helvetica').fontSize(10);
      doc.text(`N° ${sale.invoiceNumber}`, { width: w / 2, align: 'right' });
      doc.text(`Date : ${formatDateTime(new Date(sale.soldAt))}`, {
        width: w / 2,
        align: 'right',
      });
      doc.text(`Ticket : ${sale.number}`, { width: w / 2, align: 'right' });
      doc.y = Math.max(leftBottom, doc.y) + 20;

      // Client
      doc.font('Helvetica-Bold').fontSize(10).text('Client', left, doc.y);
      doc.font('Helvetica').fontSize(9);
      if (data.customer) {
        doc.text(data.customer.name);
        if (data.customer.address) doc.text(data.customer.address);
        if (data.customer.phone) doc.text(data.customer.phone);
      } else {
        doc.text('Client comptoir');
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
      for (const line of sale.lines) {
        const d = designation(data, line.productId);
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
      for (const line of sale.lines) {
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
      total('Total HT', formatDA(sale.totalHt));
      for (const [rate, amount] of byRate) {
        total(`TVA ${qty(rate)} %`, formatDA(amount));
      }
      total('Total TTC', formatDA(sale.totalTtc), true);
      doc.moveDown(0.5);
      total('Payé (espèces)', formatDA(sale.paidAmount));
      total('Reste à payer', formatDA(sale.remainingAmount));
      stampCancelled(doc, sale, left, w);
      doc
        .font('Helvetica')
        .fontSize(8)
        .text(`Vendeur : ${data.sellerName}`, left, doc.y + 20, { width: w });
    },
  );
}
