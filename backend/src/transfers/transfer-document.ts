import { ExportDocument, section } from '../common/export/export';
import { label } from '../common/export/labels';
import { formatDateTime } from '../common/pdf/pdf';
import { TransferDto } from './dto/transfer.dto';

/// Noms à imprimer (produits, emplacements, membres), résolus par l'appelant.
export interface TransferDocumentNames {
  sku(productId: string): string;
  product(productId: string): string;
  unit(productId: string): string;
  location(id: string | null | undefined): string;
  user(id: string | null | undefined): string;
}

/// Bon de transfert / de livraison (spec §8quinquies) : ce qui part du dépôt et
/// ce qui arrive au magasin, avec les signataires. AUCUN prix ni coût — le
/// document voyage avec la marchandise. Rendu par le PDF des exports.
export function transferDocument(
  transfer: TransferDto,
  names: TransferDocumentNames,
): ExportDocument {
  const when = (date: Date | null) => (date ? formatDateTime(date) : '');
  // Une étape pas encore franchie reste VIDE : « Reçu 0,000 » sur un bon en
  // route se lirait « rien reçu », alors que la réception n'a pas eu lieu.
  const once = (reached: Date | null, quantity: string) =>
    reached ? quantity : null;
  return {
    title: `Bon de transfert ${transfer.number}`,
    // Pas de flèche : absente des polices standard du PDF (WinAnsi).
    subtitle:
      `De ${names.location(transfer.fromLocationId)} vers ` +
      `${names.location(transfer.toLocationId)} · ${label(transfer.status)}` +
      (transfer.comment ? ` · ${transfer.comment}` : ''),
    filename: transfer.number,
    sections: [
      section({
        title: 'Marchandise',
        columns: [
          { header: 'Référence', value: (l) => names.sku(l.productId) },
          { header: 'Produit', value: (l) => names.product(l.productId) },
          { header: 'Unité', value: (l) => label(names.unit(l.productId)) },
          {
            header: 'Demandé',
            kind: 'quantity',
            value: (l) => l.requestedQuantity,
          },
          {
            header: 'Préparé',
            kind: 'quantity',
            value: (l) => once(transfer.preparedAt, l.preparedQuantity),
          },
          {
            header: 'Expédié',
            kind: 'quantity',
            value: (l) => once(transfer.shippedAt, l.shippedQuantity),
          },
          {
            header: 'Reçu',
            kind: 'quantity',
            value: (l) => once(transfer.receivedAt, l.receivedQuantity),
          },
        ],
        rows: transfer.lines,
      }),
      section({
        title: 'Étapes et signatures',
        columns: [
          { header: 'Étape', value: (r) => r.step },
          { header: 'Par', value: (r) => r.who },
          { header: 'Le', value: (r) => r.when },
          { header: 'Signature', value: () => '' },
        ],
        rows: [
          {
            step: 'Demandé',
            who: names.user(transfer.requestedById),
            when: when(transfer.requestedAt),
          },
          // Une seule ligne : l'expédition réécrit `preparedById` avec
          // l'expéditeur — le modèle ne garde pas les deux personnes. Séparer
          // les lignes attribuerait la préparation au mauvais membre.
          {
            step: 'Préparé / expédié',
            who: names.user(transfer.preparedById),
            when: when(transfer.shippedAt ?? transfer.preparedAt),
          },
          {
            step: 'Reçu',
            who: names.user(transfer.receivedById),
            when: when(transfer.receivedAt),
          },
        ],
      }),
    ],
  };
}
