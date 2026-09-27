/// Libellés français des codes d'enum, pour les FICHIERS exportés : ils sont
/// lus par des humains (comptable, gérant), pas par un programme. Un code
/// inconnu (valeur ajoutée plus tard) sort tel quel plutôt que vide.
const LABELS: Record<string, string> = {
  // Ventes
  VALIDEE: 'Validée',
  ANNULEE: 'Annulée',
  TICKET: 'Ticket',
  FACTURE: 'Facture',
  // Mouvements de stock
  RECEPTION: 'Réception',
  VENTE: 'Vente',
  RETOUR_CLIENT: 'Retour client',
  RETOUR_FOURNISSEUR: 'Retour fournisseur',
  TRANSFERT_SORTIE: 'Transfert (sortie)',
  TRANSFERT_ENTREE: 'Transfert (entrée)',
  AJUSTEMENT_INVENTAIRE: 'Ajustement d’inventaire',
  PERTE_CASSE: 'Perte / casse',
  // Opérations à l'origine d'un mouvement
  SALE: 'Vente',
  TRANSFER: 'Transfert',
  INVENTORY: 'Inventaire',
  MANUAL: 'Saisie manuelle',
  PURCHASE_ORDER: 'Commande',
  // Commandes fournisseurs
  BROUILLON: 'Brouillon',
  COMMANDEE: 'Commandée',
  CONFIRMEE: 'Confirmée',
  PARTIELLEMENT_RECUE: 'Partiellement reçue',
  RECUE: 'Reçue',
  CLOTUREE: 'Clôturée',
  // Inventaires
  EN_COURS: 'En cours',
  TERMINE: 'Terminé',
  COMPLET: 'Complet',
  TOURNANT: 'Tournant',
  CONFORME: 'Conforme',
  ECART: 'Écart',
  // Transferts
  DEMANDEE: 'Demandée',
  ACCEPTEE: 'Acceptée',
  EN_PREPARATION: 'En préparation',
  PREPAREE: 'Préparée',
  EN_TRANSIT: 'En transit',
  REFUSEE: 'Refusée',
  // (RECUE et ANNULEE : déjà définis plus haut, même libellé.)
  // Unités
  PIECE: 'Pièce',
  METRE: 'Mètre',
  ROULEAU: 'Rouleau',
  BOITE: 'Boîte',
  PAQUET: 'Paquet',
  KILOGRAMME: 'Kilogramme',
  // Emplacements
  MAGASIN: 'Magasin',
  DEPOT: 'Dépôt',
  TRANSIT: 'Transit',
};

export function label(code: string | null | undefined): string {
  return code ? (LABELS[code] ?? code) : '';
}
