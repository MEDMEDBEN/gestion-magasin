import { Prisma } from '../generated/prisma/client';

/// Arrondi monétaire UNIQUE du serveur (ventes, devis, commandes, réceptions,
/// étiquettes) : au centime, demi vers le haut.
export function roundMoney(value: Prisma.Decimal): number {
  return value.toDecimalPlaces(0, Prisma.Decimal.ROUND_HALF_UP).toNumber();
}

/// TVA d'un montant HT en centimes, au taux en pourcentage (« 19.00 »). Même
/// calcul partout (ligne de vente, de commande, de réception, étiquette). Sur
/// une étiquette, c'est le prix UNITAIRE : pour plusieurs mètres, la caisse
/// arrondit la TVA de la ligne entière — un écart d'au plus un demi-centime
/// par unité, comme entre le prix unitaire et le total d'un ticket.
/// TVA RETIRÉE (décision MEDMEDBEN 2026-10-05, `sandbox/tva/`) : toute
/// NOUVELLE opération (vente, devis, commande, réception) est à 0 %. Les
/// opérations passées gardent le taux figé sur leurs lignes.
export const NO_TAX = new Prisma.Decimal(0);

export function taxAmount(
  amountHt: number,
  rate: Prisma.Decimal | number,
): number {
  return roundMoney(new Prisma.Decimal(amountHt).mul(rate).div(100));
}
