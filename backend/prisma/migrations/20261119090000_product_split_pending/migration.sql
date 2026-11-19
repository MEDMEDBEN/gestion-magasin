-- Achat « en total » à répartir entre magasin et dépôt (2026-11-19).
ALTER TABLE "Product" ADD COLUMN "splitPending" BOOLEAN NOT NULL DEFAULT false;
