import { BusinessDocument } from '../common/pdf/business-document';
import { StoreIdentity } from '../settings/store-settings';
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

/// Bordereau de transfert (spec §8quinquies) : ce qui part du dépôt et ce qui
/// arrive au magasin, avec les signataires. AUCUN prix ni coût — le document
/// voyage avec la marchandise. Rendu par le document industriel commun.
export function transferDocument(
  transfer: TransferDto,
  names: TransferDocumentNames,
  store: StoreIdentity,
): BusinessDocument {
  const when = (date: Date | null) => (date ? formatDateTime(date) : '—');
  // Une étape pas encore franchie reste VIDE : « Reçu 0 » sur un bon en route
  // se lirait « rien reçu », alors que la réception n'a pas eu lieu.
  const once = (reached: Date | null, quantity: string) =>
    reached ? qty(quantity) : '';
  const stage = (step: string, who: string, at: Date | null) =>
    at ? `${step} : ${who || '—'} · ${when(at)}` : `${step} : en attente`;
  return {
    title: 'BON DE TRANSFERT',
    pdfTitle: `Bon de transfert ${transfer.number}`,
    number: transfer.number,
    meta: [
      ['Date', formatDateTime(transfer.requestedAt)],
      ['Statut', label(transfer.status)],
    ],
    store,
    parties: [
      {
        label: 'Expéditeur',
        name: names.location(transfer.fromLocationId),
        lines: [
          stage(
            'Préparé / expédié',
            names.user(transfer.preparedById),
            transfer.shippedAt ?? transfer.preparedAt,
          ),
        ],
      },
      {
        label: 'Destination',
        name: names.location(transfer.toLocationId),
        lines: [
          stage(
            'Demandé',
            names.user(transfer.requestedById),
            transfer.requestedAt,
          ),
          stage('Reçu', names.user(transfer.receivedById), transfer.receivedAt),
        ],
      },
    ],
    columns: [
      { header: 'Référence', width: 2 },
      { header: 'Désignation', width: 5.5 },
      { header: 'Unité', width: 1.2, align: 'center' },
      { header: 'Demandé', width: 1.5, align: 'right' },
      { header: 'Préparé', width: 1.5, align: 'right' },
      { header: 'Expédié', width: 1.5, align: 'right' },
      { header: 'Reçu', width: 1.5, align: 'right' },
    ],
    rows: transfer.lines.map((l) => [
      names.sku(l.productId),
      names.product(l.productId),
      label(names.unit(l.productId)),
      qty(l.requestedQuantity),
      once(transfer.preparedAt, l.preparedQuantity),
      once(transfer.shippedAt, l.shippedQuantity),
      once(transfer.receivedAt, l.receivedQuantity),
    ]),
    totals: [['Lignes', String(transfer.lines.length), true]],
    notes: transfer.comment ? [`Commentaire : ${transfer.comment}`] : [],
    signatures: ['Le demandeur', 'L’expéditeur (dépôt)', 'Le réceptionnaire'],
    paper: store.documentPaper,
  };
}

/// « 2.500 » → « 2,5 »
function qty(value: string): string {
  return value.replace(/\.?0+$/, '').replace('.', ',');
}
