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
  /// Permission réservée à l'ADMIN (docs/permissions.md § Règles fermes),
  /// non attribuable « à la carte » à un compte non administrateur.
  PERMISSION_NOT_GRANTABLE = 'PERMISSION_NOT_GRANTABLE',

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
  CREDIT_LIMIT_EXCEEDED = 'CREDIT_LIMIT_EXCEEDED',

  // Caisse (règle 12)
  CASH_SESSION_REQUIRED = 'CASH_SESSION_REQUIRED',
  CASH_SESSION_ALREADY_OPEN = 'CASH_SESSION_ALREADY_OPEN',

  // Catalogue (règle 15)
  BARCODE_ALREADY_USED = 'BARCODE_ALREADY_USED',

  // Machines à états
  INVALID_STATE_TRANSITION = 'INVALID_STATE_TRANSITION',

  // Synchronisation offline (docs/context.md)
  SYNC_MUTATION_REJECTED = 'SYNC_MUTATION_REJECTED',
  /// Échec TEMPORAIRE côté serveur : la mutation n'est pas mémorisée, le client
  /// la garde en file et la renverra telle quelle (contrat de sync § idempotence).
  SYNC_RETRY_LATER = 'SYNC_RETRY_LATER',
}
