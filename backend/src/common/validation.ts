import { applyDecorators } from '@nestjs/common';
import { Transform } from 'class-transformer';
import { IsUUID, ValidateIf } from 'class-validator';

/// Champ FACULTATIF mais jamais `null` : absent → ignoré ; présent (même `null`)
/// → validé par les décorateurs suivants.
///
/// `@IsOptional()` laisse passer `null` sans aucune validation : sur un PATCH,
/// `{ "fullName": null }` atteindrait Prisma et finirait en 500 (colonne non
/// nullable), ou effacerait silencieusement un identifiant de connexion.
export const IsOptionalNotNull = () =>
  ValidateIf((_object: object, value: unknown) => value !== undefined);

/// « true » dans une query (les paramètres d'URL sont des chaînes).
export const booleanQuery = ({ value }: { value: unknown }) =>
  value === true || value === 'true';

/// UUID reçu dans un corps ou une query : validé PUIS mis en minuscules.
///
/// Même raison que `CanonicalUuidPipe` pour les routes : PostgreSQL retrouve la
/// ligne quelle que soit la casse, pas une comparaison de chaînes côté service —
/// `parentId` en majuscules faisait d'une catégorie son propre parent.
export const IsCanonicalUuid = () =>
  applyDecorators(
    Transform(({ value }: { value: unknown }) =>
      typeof value === 'string' ? value.toLowerCase() : value,
    ),
    IsUUID(),
  );
