import { Prisma } from '../generated/prisma/client';

/// Arrondi monétaire UNIQUE du serveur : au centime, demi vers le haut.
export function roundMoney(value: Prisma.Decimal): number {
  return value.toDecimalPlaces(0, Prisma.Decimal.ROUND_HALF_UP).toNumber();
}

/// TVA d'un montant HT en centimes, au taux en pourcentage (« 19.00 »). Même
/// calcul pour la ligne de vente et pour le prix TTC imprimé sur l'étiquette :
/// le client paie en caisse ce qu'il a lu en rayon.
export function taxAmount(
  amountHt: number,
  rate: Prisma.Decimal | number,
): number {
  return roundMoney(new Prisma.Decimal(amountHt).mul(rate).div(100));
}
