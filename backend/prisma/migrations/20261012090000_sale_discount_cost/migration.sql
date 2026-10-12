-- Remise sur toute la facture ; coût figé par ligne (profit). Additif.
ALTER TABLE "Sale" ADD COLUMN "discountAmount" INTEGER NOT NULL DEFAULT 0;
ALTER TABLE "SaleLine" ADD COLUMN "costHt" INTEGER;
