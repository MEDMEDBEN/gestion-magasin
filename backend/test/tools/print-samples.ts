import { writeFileSync } from 'fs';
import { join } from 'path';
import { labelFor, renderLabels } from '../../src/products/labels';
import { SaleDto } from '../../src/sales/dto/sale.dto';
import { renderSaleDocument } from '../../src/sales/sale-document';
import { StoreIdentity } from '../../src/settings/store-settings';
import { renderBusinessDocument } from '../../src/common/pdf/business-document';
import { transferDocument } from '../../src/transfers/transfer-document';
import { TransferDto } from '../../src/transfers/dto/transfer.dto';

/// OUTIL (manuel) : écrit des PDF d'exemple pour relire la mise en page des
/// documents imprimés. `npx ts-node test/tools/print-samples.ts <dossier>`.
const out = process.argv[2] ?? '.';

const store = (over: Partial<StoreIdentity> = {}): StoreIdentity => ({
  name: 'Électricité El Nour',
  address: '12, rue des Frères Bouadou, Bir Mourad Raïs, Alger',
  phone: '0550 12 34 56',
  email: 'contact@elnour.dz',
  legal: [
    'NIF : 001216098765432',
    'RC : 16/00-1234567B21',
    'NIS : 0987654',
    'AI : 16012345678',
  ],
  footer:
    'Marchandise vendue ni reprise ni échangée sans ticket · Merci de votre confiance',
  ticketPaper: 'TICKET_80',
  documentPaper: 'A4',
  ...over,
});

const products = new Map([
  [
    'p1',
    {
      name: 'Câble souple H07RN-F 3G2,5 — couronne 100 m',
      sku: 'CAB-3G25',
      unit: 'METRE',
    },
  ],
  [
    'p2',
    { name: 'Disjoncteur DX³ 16A courbe C', sku: 'DIS-16C', unit: 'PIECE' },
  ],
  [
    'p3',
    {
      name: 'Interrupteur différentiel 40A 30mA type AC',
      sku: 'ID-40-30',
      unit: 'PIECE',
    },
  ],
  ['p4', { name: 'Réglette LED 36W 120 cm', sku: 'LED-R36', unit: 'PIECE' }],
]);

const line = (
  id: string,
  productId: string,
  quantity: string,
  price: number,
  discount = 0,
) => {
  const gross = Math.round(Number(quantity) * price);
  return {
    id,
    productId,
    quantity,
    unitPriceHt: price,
    tariffPriceHt: price,
    priceTierId: null,
    taxRate: '0.00',
    discountAmount: discount,
    lineTotalHt: gross - discount,
    lineTaxAmount: 0,
    lineTotalTtc: gross - discount,
    costHt: null,
  };
};
const lines = [
  line('l1', 'p1', '25.000', 14500),
  line('l2', 'p2', '6.000', 89000, 4000),
  line('l3', 'p3', '2.000', 1250000),
  line('l4', 'p4', '10.000', 185000),
];
const total = lines.reduce((s, l) => s + l.lineTotalTtc, 0);
const sale = (over: Partial<SaleDto> = {}) =>
  ({
    id: 's',
    number: 'TK-2026-000412',
    invoiceNumber: null,
    invoicedAt: null,
    type: 'TICKET',
    status: 'VALIDEE',
    customerId: 'c',
    userId: 'u',
    cashSessionId: null,
    totalHt: total,
    totalTax: 0,
    totalTtc: total,
    paidAmount: 5000000,
    discountAmount: 4000,
    profitHt: null,
    remainingAmount: total - 5000000,
    soldAt: new Date('2026-10-12T09:42:00Z'),
    cancelledAt: null,
    lines,
    ...over,
  }) as unknown as SaleDto;
const customer = {
  name: 'SARL Électricité Benali',
  address: 'Zone industrielle, Rouiba',
  phone: '0661 98 76 54',
};

async function main() {
  const write = (name: string, pdf: Buffer) =>
    writeFileSync(join(out, name), pdf);
  write(
    'facture-a4.pdf',
    await renderSaleDocument({
      sale: sale({
        invoiceNumber: 'FA-2026-000037',
        invoicedAt: new Date('2026-10-12T10:00:00Z'),
      }),
      store: store(),
      sellerName: 'Nadia Kaci',
      customer,
      products,
    }),
  );
  write(
    'bon-vente-a5.pdf',
    await renderSaleDocument({
      sale: sale(),
      store: store({ ticketPaper: 'A5' }),
      sellerName: 'Nadia Kaci',
      customer,
      products,
    }),
  );
  write(
    'ticket-58.pdf',
    await renderSaleDocument({
      sale: sale(),
      store: store({ ticketPaper: 'TICKET_58' }),
      sellerName: 'Nadia Kaci',
      customer: null,
      products,
    }),
  );
  const transfer = {
    id: 't',
    number: 'TRF-2026-00031',
    status: 'EN_TRANSIT',
    priority: 'NORMALE',
    fromLocationId: 'dep',
    toLocationId: 'mag',
    requestedById: 'v',
    preparedById: 'm',
    receivedById: null,
    requestedAt: new Date('2026-10-12T08:00:00Z'),
    preparedAt: new Date('2026-10-12T09:00:00Z'),
    shippedAt: new Date('2026-10-12T10:00:00Z'),
    receivedAt: null,
    comment: 'Urgent : client en attente',
    updatedAt: new Date(),
    lines: [
      {
        id: 'a',
        productId: 'p1',
        requestedQuantity: '200.000',
        preparedQuantity: '200.000',
        shippedQuantity: '200.000',
        receivedQuantity: '0.000',
      },
      {
        id: 'b',
        productId: 'p2',
        requestedQuantity: '30.000',
        preparedQuantity: '28.000',
        shippedQuantity: '28.000',
        receivedQuantity: '0.000',
      },
    ],
  } as unknown as TransferDto;
  write(
    'bordereau-a5.pdf',
    await renderBusinessDocument(
      transferDocument(
        transfer,
        {
          sku: (id) => products.get(id)!.sku,
          product: (id) => products.get(id)!.name,
          unit: (id) => products.get(id)!.unit,
          location: (id) => (id === 'dep' ? 'Dépôt central' : 'Magasin'),
          user: (id) => ({ v: 'Nadia Kaci', m: 'Karim Saidi' })[id ?? ''] ?? '',
        },
        store({ documentPaper: 'A5' }),
      ),
    ),
  );
  write(
    'etiquette-60x40.pdf',
    await renderLabels(
      [
        labelFor(
          {
            name: 'Disjoncteur DX³ 16A courbe C',
            sku: 'DIS-16C',
            barcode: '3245064074152',
            unit: 'PIECE',
          },
          89000,
        ),
      ],
      'ROULEAU',
      { widthMm: 60, heightMm: 40 },
    ),
  );
  const disj = labelFor(
    {
      name: 'Disjoncteur DX³ 16A courbe C',
      sku: 'DIS-16C',
      barcode: '4006381333931',
      unit: 'PIECE',
    },
    89000,
  );
  write(
    'etiquette-35x45.pdf',
    await renderLabels([disj], 'ROULEAU', { widthMm: 35, heightMm: 45 }),
  );
  write(
    'etiquette-45x35.pdf',
    await renderLabels([disj], 'ROULEAU', { widthMm: 45, heightMm: 35 }),
  );
  write('etiquettes-a4.pdf', await renderLabels(Array(6).fill(disj), 'A4'));
}

void main();
