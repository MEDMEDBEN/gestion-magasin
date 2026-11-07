-- Espèces remises par le client (ticket : montant reçu, monnaie rendue).
ALTER TABLE "Sale" ADD COLUMN "receivedAmount" INTEGER;
