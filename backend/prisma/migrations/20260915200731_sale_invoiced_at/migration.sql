-- AlterTable
ALTER TABLE "Sale" ADD COLUMN     "invoicedAt" TIMESTAMP(3);

-- Factures déjà émises avant cette colonne : meilleure date connue.
UPDATE "Sale" SET "invoicedAt" = "soldAt" WHERE "invoiceNumber" IS NOT NULL;
