-- Clôture du reliquat d'une commande partiellement reçue (additif).
-- Sans elle, une commande dont le fournisseur ne livrera jamais le reste
-- restait ouverte à vie : ni modifiable, ni annulable, ni recevable.
ALTER TYPE "PurchaseOrderStatus" ADD VALUE IF NOT EXISTS 'CLOTUREE';

ALTER TABLE "PurchaseOrder" ADD COLUMN IF NOT EXISTS "closedAt" TIMESTAMP(3);
ALTER TABLE "PurchaseOrder" ADD COLUMN IF NOT EXISTS "closedReason" TEXT;
