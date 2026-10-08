-- Confrère : un client relié à sa fiche fournisseur (colonne facultative, additive).
ALTER TABLE "Customer" ADD COLUMN "supplierId" UUID;
CREATE UNIQUE INDEX "Customer_supplierId_key" ON "Customer"("supplierId");
ALTER TABLE "Customer" ADD CONSTRAINT "Customer_supplierId_fkey" FOREIGN KEY ("supplierId") REFERENCES "Supplier"("id") ON DELETE SET NULL ON UPDATE CASCADE;
