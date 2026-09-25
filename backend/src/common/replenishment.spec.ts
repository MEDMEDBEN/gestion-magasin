import { Prisma } from '../generated/prisma/client';
import {
  isLowStock,
  isOutOfStock,
  suggestedOrderQuantity,
} from './replenishment';

const d = (value: string | number) => new Prisma.Decimal(value);

/// Règle du réapprovisionnement (spec §19). Une seule définition, partagée par le
/// tableau de bord, la liste de réapprovisionnement et l'alerte de stock — donc
/// éprouvée une seule fois, ici.
describe('règle de réapprovisionnement', () => {
  describe('isLowStock', () => {
    it('alerte quand le stock atteint le seuil, pas seulement en dessous', () => {
      expect(isLowStock(d(20), d(20))).toBe(true);
      expect(isLowStock(d('19.999'), d(20))).toBe(true);
      expect(isLowStock(d('20.001'), d(20))).toBe(false);
    });

    /// Le catalogue crée les produits avec un seuil à 0 : si 0 valait « alerter
    /// dès qu'il reste 0 », TOUT produit jamais réceptionné remonterait comme à
    /// racheter, et la liste serait inutilisable dès le premier jour.
    it('un seuil à 0 signifie « pas de seuil défini », pas « alerter toujours »', () => {
      expect(isLowStock(d(0), d(0))).toBe(false);
      expect(isLowStock(d(-5), d(0))).toBe(false);
    });

    it('les quantités décimales sont respectées (produits au mètre)', () => {
      expect(isLowStock(d('12.500'), d('12.500'))).toBe(true);
      expect(isLowStock(d('12.501'), d('12.500'))).toBe(false);
    });
  });

  describe('isOutOfStock', () => {
    it('rupture à zéro, et aussi en négatif (backorder autorisé)', () => {
      expect(isOutOfStock(d(0))).toBe(true);
      expect(isOutOfStock(d('-3.500'))).toBe(true);
      expect(isOutOfStock(d('0.001'))).toBe(false);
    });
  });

  describe('suggestedOrderQuantity', () => {
    /// Le point qui compte : ne JAMAIS proposer de revenir pile au seuil, sinon
    /// l'alerte retombe à la vente suivante et la proposition ne sert à rien.
    it('propose de repasser AU-DESSUS du seuil, pas dessus', () => {
      const suggested = suggestedOrderQuantity(d(8), d(20), d(0));
      expect(suggested.toString()).toBe('32');
      // Après réception : 8 + 32 = 40, soit le double du seuil.
      expect(isLowStock(d(8).plus(suggested), d(20))).toBe(false);
    });

    it('ajoute le stock de sécurité quand il est renseigné', () => {
      expect(suggestedOrderQuantity(d(8), d(20), d(5)).toString()).toBe('37');
    });

    it('jamais zéro ni négatif : plancher d’une unité', () => {
      // Produit sans seuil ni stock de sécurité, en rupture : le calcul donnerait 0.
      expect(suggestedOrderQuantity(d(0), d(0), d(0)).toString()).toBe('1');
      // Stock déjà au-dessus de la cible (cas d'un seuil abaissé après coup).
      expect(suggestedOrderQuantity(d(500), d(20), d(0)).toString()).toBe('1');
    });

    it('un stock négatif se rattrape en plus de la cible', () => {
      // 2×20 + 0 − (−5) = 45 : il faut aussi combler le découvert.
      expect(suggestedOrderQuantity(d(-5), d(20), d(0)).toString()).toBe('45');
    });

    /// Le résultat doit être FRACTIONNAIRE, sinon le test passe même si les
    /// décimales sont tronquées en route — il ne prouvait rien.
    it('garde les décimales (produit vendu au mètre)', () => {
      // 2 × 10,25 + 0 − 2,4 = 18,1
      expect(
        suggestedOrderQuantity(d('2.400'), d('10.250'), d(0)).toString(),
      ).toBe('18.1');
      // Le stock de sécurité aussi : 2 × 10 + 0,75 − 1,2 = 19,55
      expect(
        suggestedOrderQuantity(d('1.200'), d('10'), d('0.750')).toString(),
      ).toBe('19.55');
    });
  });
});
