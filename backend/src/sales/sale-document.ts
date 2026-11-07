import {
  BusinessDocument,
  DocumentColumn,
  renderBusinessDocument,
} from '../common/pdf/business-document';
import { formatDA, formatDateTime, UNIT_LABEL } from '../common/pdf/pdf';
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

/// Facture (numéro légal attribué) → FACTURE ; sinon le TICKET. Les deux sont
/// des documents complets au gabarit du devis (demande MEDMEDBEN du
/// 2026-11-07 : plus de ticket en rouleau thermique ; « TICKET » reste écrit
/// pour le distinguer d'une facture).
export function renderSaleDocument(data: SaleDocumentData): Promise<Buffer> {
  if (data.sale.invoiceNumber) return renderInvoice(data);
  return renderSaleSlip(data);
}

/// Ce que le client a donné, ce qu'on lui a rendu, ce qu'il doit encore.
function payment(sale: SaleDocumentData['sale']): [string, string][] {
  const rows: [string, string][] = [];
  const received = sale.receivedAmount ?? null;
  if (received !== null && received > sale.paidAmount) {
    rows.push(['Montant reçu', formatDA(received)]);
    rows.push(['Monnaie rendue', formatDA(received - sale.paidAmount)]);
  } else {
    rows.push(['Payé (espèces)', formatDA(sale.paidAmount)]);
  }
  if (sale.remainingAmount > 0) {
    rows.push(['Reste à payer', formatDA(sale.remainingAmount)]);
  }
  return rows;
}

/// Le ticket de caisse : un document complet, au format des documents.
function renderSaleSlip(data: SaleDocumentData): Promise<Buffer> {
  const { sale } = data;
  return renderA4Document({
    title: 'TICKET',
    pdfTitle: `Ticket ${sale.number}`,
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
    after: payment(sale),
    stamp: sale.status === 'ANNULEE' ? 'VENTE ANNULÉE' : undefined,
    wordsSubject: 'le présent ticket',
    // Une seule signature : celle du vendeur (demande du 2026-11-07).
    signatures: ['Le vendeur'],
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
    { header: 'Référence', width: 2.5 },
    { header: 'Désignation', width: 4.9 },
    { header: 'Qté', width: 1.6, align: 'right' },
    { header: taxed ? 'PU HT' : 'Prix unitaire', width: 2.8, align: 'right' },
    ...(discounted
      ? [{ header: 'Remise', width: 2.4, align: 'right' as const }]
      : []),
    ...(taxed ? [{ header: 'TVA', width: 1.2, align: 'right' as const }] : []),
    { header: taxed ? 'Total HT' : 'Montant', width: 2.6, align: 'right' },
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
  // Remise totale = remises des lignes (la remise sur facture y est déjà
  // RÉPARTIE) : dite en clair, avec le montant avant remise.
  const lineDiscounts = input.lines.reduce(
    (sum, l) => sum + (l.discountAmount ?? 0),
    0,
  );
  if (lineDiscounts > 0) {
    totals.push([
      'Montant avant remise',
      formatDA(input.totalTtc + lineDiscounts),
    ]);
    totals.push(['Remise', `- ${formatDA(lineDiscounts)}`]);
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
