import { ExportDocument, frenchDay, section } from '../common/export/export';
import {
  PurchasesReportDto,
  ReportPeriodDto,
  SalesReportDto,
  StockReportDto,
} from './dto/business-report.dto';

/// Mise en fichier des trois rapports d'activité : les MÊMES chiffres que
/// l'écran, lus par le même service. Rien n'est recalculé ici.

const periodText = (period: ReportPeriodDto) =>
  `Du ${frenchDay(period.from)} au ${frenchDay(period.to)} (${period.days} j)`;

const periodSlug = (period: ReportPeriodDto) => `${period.from}_${period.to}`;

export function salesReportDocument(report: SalesReportDto): ExportDocument {
  const t = report.totals;
  return {
    title: 'Rapport des ventes',
    subtitle:
      `${periodText(report.period)} · ventes validées · ` +
      'marge au dernier prix d’achat, hors ventes sans coût connu',
    filename: `rapport-ventes_${periodSlug(report.period)}`,
    sections: [
      section({
        title: 'Totaux',
        columns: [
          { header: 'Ventes', kind: 'integer', value: () => t.count },
          { header: 'CA HT', kind: 'money', value: () => t.revenueHt },
          { header: 'TVA', kind: 'money', value: () => t.taxAmount },
          { header: 'CA TTC', kind: 'money', value: () => t.revenueTtc },
          { header: 'Remises', kind: 'money', value: () => t.discountAmount },
          { header: 'Coût', kind: 'money', value: () => t.costHt },
          { header: 'Marge HT', kind: 'money', value: () => t.marginHt },
          {
            header: 'CA sans coût connu',
            kind: 'money',
            value: () => t.uncostedRevenueHt,
          },
        ],
        rows: [t],
      }),
      section({
        title: 'Par jour',
        columns: [
          { header: 'Jour', kind: 'date', value: (r) => r.date },
          { header: 'Ventes', kind: 'integer', value: (r) => r.count },
          { header: 'CA HT', kind: 'money', value: (r) => r.revenueHt },
        ],
        rows: report.byDay,
      }),
      section({
        title: 'Par catégorie',
        columns: [
          { header: 'Catégorie', value: (r) => r.categoryName },
          { header: 'Quantité', kind: 'quantity', value: (r) => r.quantity },
          { header: 'CA HT', kind: 'money', value: (r) => r.revenueHt },
        ],
        rows: report.byCategory,
      }),
    ],
  };
}

export function stockReportDocument(
  report: StockReportDto,
  today: string,
): ExportDocument {
  return {
    title: 'Rapport de stock',
    subtitle:
      `État au ${frenchDay(today)} · magasin et dépôt, transit exclu · ` +
      'valeur au dernier prix d’achat',
    filename: `rapport-stock_${today}`,
    sections: [
      section({
        title: 'Totaux',
        columns: [
          {
            header: 'Références en stock',
            kind: 'integer',
            value: () => report.referenceCount,
          },
          { header: 'Valeur HT', kind: 'money', value: () => report.valueHt },
          {
            header: 'Sans coût connu',
            kind: 'integer',
            value: () => report.withoutCostCount,
          },
          {
            header: 'Sous le seuil',
            kind: 'integer',
            value: () => report.lowCount,
          },
          {
            header: 'Ruptures',
            kind: 'integer',
            value: () => report.outOfStockCount,
          },
        ],
        rows: [report],
      }),
      section({
        title: 'Par emplacement',
        columns: [
          { header: 'Emplacement', value: (r) => r.locationName },
          { header: 'Type', value: (r) => r.locationType },
          {
            header: 'Références',
            kind: 'integer',
            value: (r) => r.referenceCount,
          },
          { header: 'Valeur HT', kind: 'money', value: (r) => r.valueHt },
        ],
        rows: report.byLocation,
      }),
    ],
  };
}

export function purchasesReportDocument(
  report: PurchasesReportDto,
): ExportDocument {
  return {
    title: 'Rapport des achats',
    subtitle:
      `${periodText(report.period)} · commandé et reçu comptés séparément : ` +
      'ils ne s’équilibrent pas',
    filename: `rapport-achats_${periodSlug(report.period)}`,
    sections: [
      section({
        title: 'Totaux',
        columns: [
          {
            header: 'Commandes',
            kind: 'integer',
            value: () => report.orderCount,
          },
          {
            header: 'Commandé HT',
            kind: 'money',
            value: () => report.orderedHt,
          },
          {
            header: 'Réceptions',
            kind: 'integer',
            value: () => report.receptionCount,
          },
          { header: 'Reçu HT', kind: 'money', value: () => report.receivedHt },
        ],
        rows: [report],
      }),
      section({
        title: 'Par fournisseur',
        columns: [
          { header: 'Fournisseur', value: (r) => r.supplierName },
          { header: 'Commandes', kind: 'integer', value: (r) => r.orderCount },
          { header: 'Commandé HT', kind: 'money', value: (r) => r.orderedHt },
          { header: 'Reçu HT', kind: 'money', value: (r) => r.receivedHt },
        ],
        rows: report.bySupplier,
      }),
    ],
  };
}
