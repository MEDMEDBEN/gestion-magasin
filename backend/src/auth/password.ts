import * as argon2 from 'argon2';

/// Hachage des mots de passe — SOURCE UNIQUE (services, seed, tests).
///
/// argon2id avec les paramètres par défaut de la lib, déjà conformes aux
/// recommandations OWASP. La longueur des mots de passe est bornée en amont par
/// les DTO (`PASSWORD_MAX_LENGTH`) : hacher un corps de plusieurs Mo serait un
/// déni de service à bas coût.
export function hashPassword(plain: string): Promise<string> {
  return argon2.hash(plain, { type: argon2.argon2id });
}

/// Ne lève jamais : un hash illisible vaut « mot de passe faux ».
export function verifyPassword(hash: string, plain: string): Promise<boolean> {
  return argon2.verify(hash, plain).catch(() => false);
}

/// Bornes communes à tous les DTO qui reçoivent un mot de passe.
export const PASSWORD_MIN_LENGTH = 8;
export const PASSWORD_MAX_LENGTH = 128;
