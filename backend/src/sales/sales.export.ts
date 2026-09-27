import {
  ExportDocument,
  periodLabel,
  periodSlug,
  section,
} from '../common/export/export';
import { label } from '../common/export/labels';
import { SaleDto } from './dto/sale.dto';

/// Liste des ventes : les lignes rendues par `findAll`, donc déjà cloisonnées
/// (le vendeur n'y trouve que les siennes), noms du client et du vendeur compris.
export function saleListDocument(
  rows: SaleDto[],
  period: { from?: string; to?: string },
  ownOnly: boolean,
): ExportDocument {
  return {
    title: 'Ventes',
    subtitle:
      `Ventes ${periodLabel(period.from, period.to)}` +
      (ownOnly ? ' · vos ventes uniquement' : ''),
    filename: `ventes${periodSlug(period.from, period.to)}`,
    sections: [
      section({
        columns: [
          { header: 'Ticket', value: (s) => s.number },
          { header: 'Facture', value: (s) => s.invoiceNumber },
          { header: 'Date', kind: 'date', value: (s) => s.soldAt },
          { header: 'Statut', value: (s) => label(s.status) },
          {
            header: 'Client',
            value: (s) => s.customerName ?? '',
          },
          { header: 'Vendeur', value: (s) => s.sellerName },
          { header: 'HT', kind: 'money', value: (s) => s.totalHt },
          { header: 'TVA', kind: 'money', value: (s) => s.totalTax },
          { header: 'TTC', kind: 'money', value: (s) => s.totalTtc },
          { header: 'Encaissé', kind: 'money', value: (s) => s.paidAmount },
          {
            header: 'Reste dû',
            kind: 'money',
            value: (s) => s.remainingAmount,
          },
          {
            header: 'Échéance',
            kind: 'date',
            // Date PURE (minuit UTC) : montrée comme un jour, pas une heure.
            value: (s) => s.dueDate?.toISOString().slice(0, 10) ?? null,
          },
        ],
        rows,
      }),
    ],
  };
}
