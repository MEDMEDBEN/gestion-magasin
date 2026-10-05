# TVA — taux par produit, ventilation HT / TVA / TTC

Retirée du projet le **2026-10-05** (décision MEDMEDBEN : plus de TVA du tout ; le prix saisi est le
prix payé). État complet d'avant : tag git `avant-retrait-tva`.

## Ce que faisait la fonctionnalité

- Un **taux de TVA par produit** (`Product.taxRateId` → table `TaxRate`), un taux **par défaut**
  proposé à la création, géré par l'admin dans Paramètres (`/pricing/tax-rates`, CRUD + audit).
- Chaque ligne de vente, devis, commande fournisseur et réception **fige** son taux
  (`taxRate`, `lineTaxAmount`) ; totaux HT / TVA / TTC ; arrondi au centime demi vers le haut
  (`taxAmount` dans `backend/src/common/money.ts`).
- Étiquettes au prix TTC ; tickets et factures avec colonne TVA et ventilation par taux ;
  import produits avec colonne « TVA % » ; « TVA collectée » dans les rapports.
- L'app estimait le TTC du panier hors ligne avec les taux du catalogue local (même arrondi que le
  serveur, contrôlé par `expectedTotalTtc`).

## Ce qui reste dans ce projet (et pourquoi)

- **Base intacte** : table `TaxRate`, colonnes `taxRateId` / `taxRate` / `lineTaxAmount` / `totalTax`.
  Les opérations d'avant gardent leur TVA, et les documents d'avant l'affichent toujours.
- Règle actuelle : `NO_TAX` (0 %) pour toute nouvelle opération (`backend/src/common/money.ts`).
  Une réception sur une commande d'avant garde le taux figé de la commande.

## Contenu

| Chemin | Rôle |
|---|---|
| `backend-restore.patch` | Remet **tout le backend** comme avant le retrait (calcul, routes `/pricing/tax-rates`, DTO, import, étiquettes, documents). |
| `app-avant/` | Versions d'avant des fichiers de l'app : écran Paramètres (carte « Taux de TVA »), API Paramètres, fiche produit (champ TVA), estimation du panier, totaux du panier. |

## Réintégrer dans ce projet

```bash
git apply --3way sandbox/tva/backend-restore.patch
```
Puis reprendre dans l'app, depuis `app-avant/`, la carte `_TaxRatesCard`, le champ TVA de la fiche
produit et le calcul de TVA de `estimateCart` (et remettre les tests e2e du tag).

## Réutiliser ailleurs

Il faut : NestJS + Prisma, un modèle `TaxRate` (code, nom, taux `Decimal(5,2)`, `isDefault`,
`isActive`), un `taxRateId` optionnel sur le produit, et les champs figés sur chaque ligne.
