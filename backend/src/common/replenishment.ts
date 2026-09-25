import { Prisma } from '../generated/prisma/client';

/// Emplacements qui portent du stock RÉELLEMENT disponible.
///
/// `TRANSIT` est exclu partout où l'on juge s'il faut réapprovisionner : une
/// marchandise en route n'est pas sur l'étagère. Cette liste est la seule de son
/// espèce — le tableau de bord, la liste de réapprovisionnement et l'alerte de
/// stock la partagent, sinon les trois finissent par ne plus dire la même chose.
export const STOCK_BEARING_LOCATIONS = ['MAGASIN', 'DEPOT'] as const;

/// Produit à réapprovisionner (spec §19) : `stock <= seuil minimum`.
///
/// Un seuil à 0 ne signifie PAS « alerter en permanence » mais « pas de seuil
/// défini » : dans ce cas seule la rupture (`isOutOfStock`) parle.
export function isLowStock(
  quantity: Prisma.Decimal,
  minThreshold: Prisma.Decimal,
): boolean {
  return (
    minThreshold.greaterThan(0) && quantity.lessThanOrEqualTo(minThreshold)
  );
}

export function isOutOfStock(quantity: Prisma.Decimal): boolean {
  return quantity.lessThanOrEqualTo(0);
}

/// Quantité proposée à commander. L'utilisateur la modifie avant de commander
/// (spec §19) : ce n'est qu'un point de départ.
///
/// Cible = **deux fois** le seuil, plus le stock de sécurité. Pourquoi le
/// double : commander juste de quoi revenir AU seuil laisse le produit sur le
/// seuil, donc l'alerte retombe à la vente suivante — la proposition serait
/// inutile. Le plancher d'une unité évite une proposition à zéro sur un produit
/// sans seuil ni stock de sécurité (le cas par défaut du catalogue).
///
/// ⚠️ Le multiplicateur est un CHOIX, pas une donnée : la spec §19 illustre
/// « stock 8, seuil 20 → 50 », soit un facteur plus large encore. Rien dans la
/// base ne permet de le calculer aujourd'hui — vitesse de vente, délai
/// fournisseur et saisonnalité sont explicitement remis à P2 (n°22). À
/// confirmer par MEDMEDBEN ; le changer ne touche que cette fonction.
export function suggestedOrderQuantity(
  quantity: Prisma.Decimal,
  minThreshold: Prisma.Decimal,
  safetyStock: Prisma.Decimal,
): Prisma.Decimal {
  const target = minThreshold.times(2).plus(safetyStock);
  const missing = target.minus(quantity);
  return missing.greaterThan(1) ? missing : new Prisma.Decimal(1);
}
