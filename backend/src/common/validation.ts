import { ValidateIf } from 'class-validator';

/// Champ FACULTATIF mais jamais `null` : absent → ignoré ; présent (même `null`)
/// → validé par les décorateurs suivants.
///
/// `@IsOptional()` laisse passer `null` sans aucune validation : sur un PATCH,
/// `{ "fullName": null }` atteindrait Prisma et finirait en 500 (colonne non
/// nullable), ou effacerait silencieusement un identifiant de connexion.
export const IsOptionalNotNull = () =>
  ValidateIf((_object: object, value: unknown) => value !== undefined);
