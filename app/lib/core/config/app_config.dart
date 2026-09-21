/// Constantes du contrat client/serveur.
///
/// Les bornes offline viennent de `docs/context.md` § « Bornes de données offline » :
/// les modifier a un effet direct sur la fiabilité du stock hors-ligne.
class AppConfig {
  const AppConfig._();

  /// URL du backend. Surchargeable au build :
  /// `flutter run --dart-define=API_BASE_URL=https://api.tondomaine.com`
  static const String apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://localhost:3000/api',
  );

  /// Taille maximale d'un lot envoyé à `POST /sync` — le serveur refuse au-delà.
  static const int maxMutationsPerBatch = 200;

  /// Au-delà, l'app alerte et restreint les opérations sensibles :
  /// un appareil trop longtemps hors-ligne travaille sur un stock trop faux.
  static const int maxPendingMutations = 200;
  static const Duration maxOfflineDuration = Duration(hours: 72);

  /// Battement de la synchronisation : la file est poussée à cet intervalle tant
  /// qu'une session est ouverte (une file vide ne coûte aucun appel réseau —
  /// elle ne sonde donc pas le serveur).
  static const Duration syncInterval = Duration(seconds: 30);

  /// Historique conservé en local ; au-delà, consultable en ligne uniquement.
  static const int localHistoryDays = 30;

  /// L'access token dure 15 min côté serveur.
  static const Duration requestTimeout = Duration(seconds: 30);

  /// Refuse de démarrer une build RELEASE pointée sur une URL non chiffrée :
  /// mots de passe et refresh tokens (90 j) passeraient en clair sur le réseau
  /// — et Windows, contrairement à Android/iOS, ne bloque pas le HTTP en clair.
  /// En debug, `http://localhost` reste permis pour le développement.
  static void assertSecureTransport({
    required bool isRelease,
    String url = apiBaseUrl,
  }) {
    if (isRelease && Uri.parse(url).scheme != 'https') {
      throw StateError(
        'API_BASE_URL doit être en https:// dans une build release (reçu : $url)',
      );
    }
  }
}
