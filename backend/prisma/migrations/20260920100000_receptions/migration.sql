-- Réceptions (P0 #7) — additif uniquement.
-- Numérotation propre aux bons de réception (BR-AAAA-NNNNN).
ALTER TYPE "DocumentType" ADD VALUE IF NOT EXISTS 'RECEPTION';

-- Montant TTC figé à la réception : c'est lui qui s'ajoute à la dette
-- fournisseur, même si le taux de TVA du produit change plus tard.
ALTER TABLE "ReceptionLine" ADD COLUMN IF NOT EXISTS "lineTotalTtc" INTEGER NOT NULL DEFAULT 0;
