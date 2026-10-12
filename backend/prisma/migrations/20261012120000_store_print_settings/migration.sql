-- Réglages d'impression du magasin (formats, étiquette, pied de page). Additif.
ALTER TABLE "StoreSettings" ADD COLUMN "email" TEXT;
ALTER TABLE "StoreSettings" ADD COLUMN "footer" TEXT;
ALTER TABLE "StoreSettings" ADD COLUMN "ticketPaper" TEXT NOT NULL DEFAULT 'TICKET_80';
ALTER TABLE "StoreSettings" ADD COLUMN "documentPaper" TEXT NOT NULL DEFAULT 'A4';
ALTER TABLE "StoreSettings" ADD COLUMN "labelWidthMm" INTEGER NOT NULL DEFAULT 50;
ALTER TABLE "StoreSettings" ADD COLUMN "labelHeightMm" INTEGER NOT NULL DEFAULT 30;
