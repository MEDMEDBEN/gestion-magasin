/// QUANTITÉ UNIQUE (décision MEDMEDBEN du 2026-11-23) : un produit n'a plus
/// qu'UNE quantité, tous lieux confondus. Tout le stock entre et sort par le
/// MAGASIN ; le dépôt (et son stock d'avant, versé au magasin) reste en base,
/// avec son historique.
///
/// Les écrans du dépôt (transferts, demandes au dépôt, « à répartir », choix
/// du lieu) sont CACHÉS, pas supprimés : passer cette valeur à `true` les
/// fait revenir.
const depotEnabled = false;

/// Type du lieu où tout le stock entre et sort.
const stockLocationType = 'MAGASIN';

/// Lieux où l'on compte, reçoit, perd du stock : le magasin seul (avec le
/// dépôt quand il revient).
bool isStockLocationType(String type) =>
    type == stockLocationType || (depotEnabled && type == 'DEPOT');
