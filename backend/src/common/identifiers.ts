/// Normalisation des identifiants de connexion (email / téléphone).
///
/// Appliquée à l'ÉCRITURE (création, modification de compte) ET à la LECTURE
/// (login) : sans cela, `Karim@x.dz` ne pourrait pas se connecter en tapant
/// `karim@x.dz`, et deux comptes ne différant que par la casse coexisteraient.

export const EMAIL_MAX_LENGTH = 254;

/// Chiffres uniquement, `+` international optionnel : 6 à 15 chiffres (E.164).
/// Un email contient toujours `@` : les deux formats ne peuvent pas se confondre,
/// le login sait donc sans ambiguïté quelle colonne interroger.
export const PHONE_PATTERN = /^\+?[0-9]{6,15}$/;

export function normalizeEmail(value: unknown): unknown {
  return typeof value === 'string' ? value.trim().toLowerCase() : value;
}

/// Retire la ponctuation de saisie courante (`0555 12-34.56`, `(0555)…`).
export function normalizePhone(value: unknown): unknown {
  return typeof value === 'string' ? value.replace(/[\s.\-()]/g, '') : value;
}

export function isEmailIdentifier(identifier: string): boolean {
  return identifier.includes('@');
}

/// Identifiant saisi au login : email OU téléphone, normalisé selon sa forme.
export function normalizeIdentifier(value: unknown): unknown {
  if (typeof value !== 'string') return value;
  return isEmailIdentifier(value)
    ? normalizeEmail(value)
    : normalizePhone(value);
}
