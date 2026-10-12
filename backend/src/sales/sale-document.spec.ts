import { SaleDto } from './dto/sale.dto';
import { renderSaleDocument, SaleDocumentData } from './sale-document';

const pages = (pdf: Buffer) =>
  (pdf.toString('latin1').match(/\/Type \/Page\b(?!s)/g) ?? []).length;

function data(
  lines: number,
  nameLength: number,
  ticketPaper: SaleDocumentData['store']['ticketPaper'] = 'TICKET_80',
): SaleDocumentData {
  const sale = {
    id: 's',
    number: 'TK-2026-000001',
    invoiceNumber: null,
    invoicedAt: null,
    type: 'TICKET',
    status: 'VALIDEE',
    customerId: 'c',
    userId: 'u',
    cashSessionId: null,
    totalHt: 0,
    totalTax: 0,
    totalTtc: 0,
    paidAmount: 0,
    remainingAmount: 0,
    soldAt: new Date('2026-09-15T10:00:00Z'),
    cancelledAt: null,
    lines: Array.from({ length: lines }, (_, i) => ({
      id: `l${i}`,
      productId: `p${i}`,
      quantity: '1.000',
      unitPriceHt: 99_999_999,
      priceTierId: null,
      taxRate: '19.00',
      discountAmount: 1,
      lineTotalHt: 99_999_998,
      lineTaxAmount: 19_000_000,
      lineTotalTtc: 118_999_998,
    })),
  } as unknown as SaleDto;
  return {
    sale,
    sellerName: 'Vendeur',
    customer: { name: 'W'.repeat(120), address: null, phone: null },
    store: {
      name: 'Magasin',
      address: 'A'.repeat(200),
      phone: '0',
      legal: ['NIF : 1', 'RC : 2', 'NIS : 3', 'AI : 4'],
      ticketPaper,
      documentPaper: 'A4',
    },
    products: new Map(
      sale.lines.map((l) => [
        l.productId,
        { name: 'W'.repeat(nameLength), sku: 'SKU', unit: 'PIECE' },
      ]),
    ),
  };
}

describe('tickets en rouleau (80 et 58 mm)', () => {
  // Un rouleau coupé au milieu du ticket est inutilisable : UNE page, toujours.
  it.each([
    [1, 10],
    [10, 150],
    [40, 60],
    [200, 150],
  ])('%i lignes, désignations de %i caractères → 1 page', async (n, len) => {
    expect(pages(await renderSaleDocument(data(n, len)))).toBe(1);
    expect(pages(await renderSaleDocument(data(n, len, 'TICKET_58')))).toBe(1);
  });
});

describe('ticket imprimé en bon de vente (A5 / A4)', () => {
  it('format de page choisi, plusieurs pages si besoin, en-tête répété', async () => {
    const a5 = await renderSaleDocument(data(3, 20, 'A5'));
    // A5 = 419,53 × 595,28 pt.
    expect(a5.toString('latin1')).toMatch(/MediaBox \[0 0 419\.5/);
    expect(pages(a5)).toBe(1);
    expect(pages(await renderSaleDocument(data(80, 40, 'A4')))).toBeGreaterThan(
      1,
    );
  });
});
