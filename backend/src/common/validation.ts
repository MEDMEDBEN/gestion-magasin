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
/// Identifiant généré par le CLIENT à la création (contrat de sync §1) :
/// facultatif, mais JAMAIS `null`. `@IsOptional()` laisse passer `null` sans
/// rien valider ; `{ "id": null }` atteignait alors Prisma et finissait en 500
/// sur toutes les routes de création (audit sécurité du 2026-09-21). Un seul
/// décorateur pour tous les DTO : la correction ne peut plus manquer à l'un.
export const ClientGeneratedId = () =>
  applyDecorators(IsOptionalNotNull(), IsCanonicalUuid());

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
