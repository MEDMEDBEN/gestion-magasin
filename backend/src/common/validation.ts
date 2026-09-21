import { applyDecorators } from '@nestjs/common';
import { Transform } from 'class-transformer';
import { IsUUID, ValidateIf, ValidationOptions } from 'class-validator';

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
/// `{ each: true }` couvre un TABLEAU d'UUID : chaque élément est mis en
/// minuscules puis validé, comme un champ simple.
export const IsCanonicalUuid = (options?: ValidationOptions) =>
  applyDecorators(
    Transform(({ value }: { value: unknown }) => {
      const canonical = (item: unknown) =>
        typeof item === 'string' ? item.toLowerCase() : item;
      return Array.isArray(value) ? value.map(canonical) : canonical(value);
    }),
    IsUUID('all', options),
  );
