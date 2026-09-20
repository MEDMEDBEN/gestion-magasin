-- Total TTC figé sur le bon de réception : la dette fournisseur se somme sans
-- charger toutes les lignes. Additif ; backfill des bons existants au passage
-- (aucun en base aujourd'hui, mais la colonne ne doit jamais mentir).
ALTER TABLE "Reception" ADD COLUMN IF NOT EXISTS "totalTtc" INTEGER NOT NULL DEFAULT 0;

UPDATE "Reception" r
SET "totalTtc" = COALESCE(
  (SELECT SUM(l."lineTotalTtc") FROM "ReceptionLine" l WHERE l."receptionId" = r."id"),
  0
);
