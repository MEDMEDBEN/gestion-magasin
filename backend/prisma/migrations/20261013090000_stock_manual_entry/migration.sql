-- Entrée de stock manuelle (décision MEDMEDBEN du 2026-10-13) : ajouter une
-- quantité à un produit existant sans passer par un achat, tracée (auteur, motif).
ALTER TYPE "StockMovementType" ADD VALUE 'ENTREE_MANUELLE';
