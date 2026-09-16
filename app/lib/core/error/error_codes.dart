/// Miroir EXACT de `backend/src/common/error-codes.ts`.
///
/// Le client se base TOUJOURS sur ce code, jamais sur le texte du message
/// (CONVENTIONS.md § Format de réponse & erreurs).
class ErrorCodes {
  const ErrorCodes._();

  // Authentification / session
  static const String invalidCredentials = 'INVALID_CREDENTIALS';
  static const String accountDisabled = 'ACCOUNT_DISABLED';
  static const String passwordChangeRequired = 'PASSWORD_CHANGE_REQUIRED';
  static const String accessTokenMissing = 'ACCESS_TOKEN_MISSING';
  static const String accessTokenInvalid = 'ACCESS_TOKEN_INVALID';
  static const String refreshTokenInvalid = 'REFRESH_TOKEN_INVALID';
  static const String refreshTokenExpired = 'REFRESH_TOKEN_EXPIRED';
  static const String refreshTokenRevoked = 'REFRESH_TOKEN_REVOKED';
  static const String forbiddenRole = 'FORBIDDEN_ROLE';
  static const String forbiddenPermission = 'FORBIDDEN_PERMISSION';
  static const String currentPasswordInvalid = 'CURRENT_PASSWORD_INVALID';

  // Gestion des comptes
  static const String selfModificationForbidden = 'SELF_MODIFICATION_FORBIDDEN';
  static const String lastActiveAdmin = 'LAST_ACTIVE_ADMIN';

  // Générique
  static const String validationFailed = 'VALIDATION_FAILED';
  static const String notFound = 'NOT_FOUND';
  static const String conflict = 'CONFLICT';
  static const String notImplemented = 'NOT_IMPLEMENTED';
  static const String rateLimited = 'RATE_LIMITED';

  // Stock
  static const String stockNegative = 'STOCK_NEGATIVE';
  static const String stockInsufficient = 'STOCK_INSUFFICIENT';

  // Ventes / facturation
  static const String invoiceOnlineOnly = 'INVOICE_ONLINE_ONLY';
  static const String priceNotDefined = 'PRICE_NOT_DEFINED';
  static const String discountNotAllowed = 'DISCOUNT_NOT_ALLOWED';
  static const String creditLimitExceeded = 'CREDIT_LIMIT_EXCEEDED';
  static const String saleTotalChanged = 'SALE_TOTAL_CHANGED';
  static const String saleAlreadyRecorded = 'SALE_ALREADY_RECORDED';
  static const String paymentAlreadyRecorded = 'PAYMENT_ALREADY_RECORDED';

  // Caisse
  static const String cashSessionRequired = 'CASH_SESSION_REQUIRED';
  static const String cashSessionAlreadyOpen = 'CASH_SESSION_ALREADY_OPEN';

  // Catalogue
  static const String barcodeAlreadyUsed = 'BARCODE_ALREADY_USED';

  // Machines à états
  static const String invalidStateTransition = 'INVALID_STATE_TRANSITION';

  // Synchronisation
  static const String syncMutationRejected = 'SYNC_MUTATION_REJECTED';

  /// Échec TEMPORAIRE : la mutation n'est pas mémorisée côté serveur,
  /// le client la GARDE en file et la renverra telle quelle.
  static const String syncRetryLater = 'SYNC_RETRY_LATER';

  /// Codes qui exigent une reconnexion : le refresh ne peut rien y faire.
  static const Set<String> requiresRelogin = {
    refreshTokenInvalid,
    refreshTokenExpired,
    refreshTokenRevoked,
    accountDisabled,
  };

  /// Messages destinés à l'utilisateur, en français, dérivés du code stable.
  static String userMessage(String? code, String fallback) => switch (code) {
    invalidCredentials => 'Identifiant ou mot de passe incorrect',
    currentPasswordInvalid => 'Mot de passe actuel incorrect',
    accountDisabled => 'Ce compte est désactivé',
    passwordChangeRequired => 'Vous devez changer votre mot de passe',
    refreshTokenExpired ||
    refreshTokenRevoked ||
    refreshTokenInvalid => 'Session expirée, reconnectez-vous',
    forbiddenRole ||
    forbiddenPermission => "Vous n'avez pas les droits pour cette action",
    selfModificationForbidden =>
      'Vos rôles et votre activation sont modifiés par un autre administrateur',
    lastActiveAdmin =>
      'Impossible : ce compte est le dernier administrateur actif',
    rateLimited => 'Trop de tentatives. Patientez quelques minutes.',
    stockNegative ||
    stockInsufficient => 'Stock insuffisant pour cette opération',
    cashSessionRequired => 'Ouvrez une session de caisse au préalable',
    invoiceOnlineOnly =>
      'La facturation exige une connexion — le ticket reste valable',
    creditLimitExceeded => 'Limite de crédit du client dépassée',
    notImplemented => "Fonctionnalité pas encore disponible",
    _ => fallback,
  };
}
