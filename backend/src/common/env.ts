/// Lecture et validation de la configuration d'environnement.
///
/// Refuser de démarrer sur une configuration dangereuse vaut mieux que tourner
/// silencieusement avec : une clé JWT d'exemple permettrait à n'importe qui de
/// forger un token ADMIN, une limite `NaN` désactiverait l'anti-brute-force.

/// Valeur d'exemple publiée dans `.env.example` — jamais acceptable en vrai.
const EXAMPLE_JWT_SECRET = 'CHANGER_CETTE_CLE_ALEATOIRE';

/// HS256 : une clé plus courte que la sortie du hash affaiblit la signature.
const MIN_JWT_SECRET_BYTES = 32;

/// Variables entières, avec leur valeur minimale admise.
const INTEGER_VARIABLES: Record<string, number> = {
  JWT_ACCESS_EXPIRES_SECONDS: 1,
  JWT_REFRESH_EXPIRES_DAYS: 1,
  AUTH_LOGIN_LIMIT: 1,
  AUTH_REFRESH_LIMIT: 1,
  AUTH_CHANGE_PASSWORD_LIMIT: 1,
  API_RATE_LIMIT: 1,
  TRUST_PROXY_HOPS: 0,
  PORT: 1,
};

function isIntegerAtLeast(raw: unknown, min: number): boolean {
  if (typeof raw === 'number') return Number.isInteger(raw) && raw >= min;
  if (typeof raw !== 'string' || !/^\d+$/.test(raw.trim())) return false;
  return Number(raw) >= min;
}

/// Branché sur `ConfigModule.forRoot({ validate })` : exécuté au démarrage,
/// après chargement du `.env`. Lève une erreur listant TOUS les problèmes.
export function validateEnv(
  config: Record<string, unknown>,
): Record<string, unknown> {
  const errors: string[] = [];

  if (!config.DATABASE_URL) {
    errors.push('DATABASE_URL est absent');
  }

  const secret = config.JWT_ACCESS_SECRET;
  if (typeof secret !== 'string' || secret.length === 0) {
    errors.push('JWT_ACCESS_SECRET est absent');
  } else if (secret === EXAMPLE_JWT_SECRET) {
    errors.push('JWT_ACCESS_SECRET vaut la valeur d’exemple de .env.example');
  } else if (Buffer.byteLength(secret, 'utf8') < MIN_JWT_SECRET_BYTES) {
    errors.push(
      `JWT_ACCESS_SECRET trop court : ${MIN_JWT_SECRET_BYTES} octets minimum ` +
        '(openssl rand -base64 48)',
    );
  }

  for (const [name, min] of Object.entries(INTEGER_VARIABLES)) {
    const raw = config[name];
    if (raw === undefined || raw === '') continue;
    if (!isIntegerAtLeast(raw, min)) {
      errors.push(`${name} doit être un entier ≥ ${min} (reçu : « ${String(raw)} »)`);
    }
  }

  if (errors.length > 0) {
    throw new Error(
      `Configuration invalide — refus de démarrer :\n - ${errors.join('\n - ')}`,
    );
  }
  return config;
}

/// Entier lu dans l'environnement AU MOMENT de l'appel (et non à l'import du
/// module : le `.env` n'est chargé qu'ensuite par ConfigModule).
///
/// Une valeur présente mais invalide lève une erreur au lieu de retomber sur
/// `fallback` : une faute de frappe ne doit pas désactiver une protection.
export function intFromEnv(name: string, fallback: number, min = 1): number {
  const raw = process.env[name];
  if (raw === undefined || raw === '') return fallback;
  if (!isIntegerAtLeast(raw, min)) {
    throw new Error(`${name} doit être un entier ≥ ${min} (reçu : « ${raw} »)`);
  }
  return Number(raw);
}
