/// Codes métier STABLES destinés au client Flutter.
/// Le front s'y réfère TOUJOURS par ce code, jamais par le texte du message
/// (voir CONVENTIONS.md § Format de réponse & erreurs).
export enum ErrorCode {
  // Authentification / session
  INVALID_CREDENTIALS = 'INVALID_CREDENTIALS',
  ACCOUNT_DISABLED = 'ACCOUNT_DISABLED',
  PASSWORD_CHANGE_REQUIRED = 'PASSWORD_CHANGE_REQUIRED',
  /// Access token : absent, malformé ou expiré → le client tente un /auth/refresh.
  ACCESS_TOKEN_MISSING = 'ACCESS_TOKEN_MISSING',
  ACCESS_TOKEN_INVALID = 'ACCESS_TOKEN_INVALID',
  REFRESH_TOKEN_INVALID = 'REFRESH_TOKEN_INVALID',
  REFRESH_TOKEN_EXPIRED = 'REFRESH_TOKEN_EXPIRED',
  REFRESH_TOKEN_REVOKED = 'REFRESH_TOKEN_REVOKED',
  FORBIDDEN_ROLE = 'FORBIDDEN_ROLE',
  FORBIDDEN_PERMISSION = 'FORBIDDEN_PERMISSION',
  /// Changement de mot de passe : le mot de passe ACTUEL saisi est faux
  /// (distinct d'INVALID_CREDENTIALS, qui concerne la connexion).
  CURRENT_PASSWORD_INVALID = 'CURRENT_PASSWORD_INVALID',

  // Gestion des comptes
  /// Un admin ne modifie ni ses propres rôles, ni sa propre activation.
  SELF_MODIFICATION_FORBIDDEN = 'SELF_MODIFICATION_FORBIDDEN',
  /// L'opération laisserait le système sans aucun administrateur actif.
  LAST_ACTIVE_ADMIN = 'LAST_ACTIVE_ADMIN',

  // Générique
  VALIDATION_FAILED = 'VALIDATION_FAILED',
  NOT_FOUND = 'NOT_FOUND',
  CONFLICT = 'CONFLICT',
  NOT_IMPLEMENTED = 'NOT_IMPLEMENTED',
  /// Trop de requêtes dans la fenêtre (anti-brute-force) : réessayer plus tard.
  RATE_LIMITED = 'RATE_LIMITED',

  // Stock (règles 2, 9 de CLAUDE.md)
  STOCK_NEGATIVE = 'STOCK_NEGATIVE',
  STOCK_INSUFFICIENT = 'STOCK_INSUFFICIENT',

  // Ventes / facturation (règles 11, 13)
  INVOICE_ONLINE_ONLY = 'INVOICE_ONLINE_ONLY',
  PRICE_NOT_DEFINED = 'PRICE_NOT_DEFINED',
  DISCOUNT_NOT_ALLOWED = 'DISCOUNT_NOT_ALLOWED',
  /// Prix saisi en vente sous le dernier prix d'achat : jamais de vente à perte
  /// (décision MEDMEDBEN 2026-09-22).
  PRICE_BELOW_COST = 'PRICE_BELOW_COST',
  CREDIT_LIMIT_EXCEEDED = 'CREDIT_LIMIT_EXCEEDED',
  /// Total calculé serveur ≠ total annoncé au client (prix changé) : rien écrit.
  SALE_TOTAL_CHANGED = 'SALE_TOTAL_CHANGED',
  /// Id de vente déjà enregistré avec un AUTRE panier : la première vente EXISTE
  /// (stock sorti, espèces en caisse) — ne pas la refaire à l'aveugle.
  SALE_ALREADY_RECORDED = 'SALE_ALREADY_RECORDED',
  /// Id de règlement/paiement déjà enregistré avec un AUTRE contenu : le
  /// premier paiement EXISTE (dette réduite, caisse mouvementée).
  PAYMENT_ALREADY_RECORDED = 'PAYMENT_ALREADY_RECORDED',
  /// Facture demandée sans les mentions légales du magasin (STORE_NIF, STORE_RC).
  STORE_IDENTITY_MISSING = 'STORE_IDENTITY_MISSING',

  // Caisse (règle 12)
  CASH_SESSION_REQUIRED = 'CASH_SESSION_REQUIRED',
  CASH_SESSION_ALREADY_OPEN = 'CASH_SESSION_ALREADY_OPEN',
  /// Sortie de caisse supérieure aux espèces réellement dans le tiroir.
  CASH_INSUFFICIENT = 'CASH_INSUFFICIENT',
  /// Vente hors-ligne antérieure à l'ouverture de la caisse actuelle : ses
  /// espèces appartiennent à une caisse CLÔTURÉE (ou à aucune) — les imputer à
  /// celle-ci fausserait les deux rapports Z.
  CASH_SESSION_CLOSED = 'CASH_SESSION_CLOSED',

  // Catalogue (règle 15)
  BARCODE_ALREADY_USED = 'BARCODE_ALREADY_USED',

  // Inventaire (spec §22)
  /// Un AUTRE inventaire a déjà corrigé ces produits depuis ce comptage : le
  /// même écart serait appliqué deux fois. (Une vente ou une réception, elles,
  /// ne gênent pas : l'ajustement est un delta, il s'y ajoute.)
  INVENTORY_STALE_COUNT = 'INVENTORY_STALE_COUNT',

  // Machines à états
  INVALID_STATE_TRANSITION = 'INVALID_STATE_TRANSITION',

  // Synchronisation offline (docs/context.md)
  SYNC_MUTATION_REJECTED = 'SYNC_MUTATION_REJECTED',
  /// Échec TEMPORAIRE côté serveur : la mutation n'est pas mémorisée, le client
  /// la garde en file et la renverra telle quelle (contrat de sync § idempotence).
  SYNC_RETRY_LATER = 'SYNC_RETRY_LATER',
  /// Le lot déclare un auteur qui n'est pas le porteur de la session : rien
  /// n'est traité ni mémorisé, les mutations restent en file côté appareil.
  SYNC_AUTHOR_MISMATCH = 'SYNC_AUTHOR_MISMATCH',
}
