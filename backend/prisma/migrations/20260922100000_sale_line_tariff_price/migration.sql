-- Prix du tarif conservé à côté du prix appliqué (prix modifiable en vente).
ALTER TABLE "SaleLine" ADD COLUMN "tariffPriceHt" INTEGER;

-- Les ventes passées ont toutes été faites au prix du tarif.
UPDATE "SaleLine" SET "tariffPriceHt" = "unitPriceHt";
