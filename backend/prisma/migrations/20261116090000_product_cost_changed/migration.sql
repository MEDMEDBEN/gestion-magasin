-- Prix d'achat changé par une réception : prix de vente à revoir (2026-11-16).
ALTER TABLE "Product" ADD COLUMN "costChangedAt" TIMESTAMP(3);
