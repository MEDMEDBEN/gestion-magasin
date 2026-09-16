-- AlterTable
ALTER TABLE "CashSession" ADD COLUMN     "closeMutationId" UUID,
ADD COLUMN     "openMutationId" UUID;

-- AlterTable
ALTER TABLE "CustomerPayment" ADD COLUMN     "reversesPaymentId" UUID;

-- AlterTable
ALTER TABLE "SupplierPayment" ADD COLUMN     "clientMutationId" UUID,
ADD COLUMN     "reversesPaymentId" UUID;

-- CreateIndex
CREATE UNIQUE INDEX "CashSession_openMutationId_key" ON "CashSession"("openMutationId");

-- CreateIndex
CREATE UNIQUE INDEX "CashSession_closeMutationId_key" ON "CashSession"("closeMutationId");

-- CreateIndex
CREATE UNIQUE INDEX "CustomerPayment_reversesPaymentId_key" ON "CustomerPayment"("reversesPaymentId");

-- CreateIndex
CREATE UNIQUE INDEX "SupplierPayment_clientMutationId_key" ON "SupplierPayment"("clientMutationId");

-- CreateIndex
CREATE UNIQUE INDEX "SupplierPayment_reversesPaymentId_key" ON "SupplierPayment"("reversesPaymentId");

-- AddForeignKey
ALTER TABLE "CustomerPayment" ADD CONSTRAINT "CustomerPayment_reversesPaymentId_fkey" FOREIGN KEY ("reversesPaymentId") REFERENCES "CustomerPayment"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "SupplierPayment" ADD CONSTRAINT "SupplierPayment_reversesPaymentId_fkey" FOREIGN KEY ("reversesPaymentId") REFERENCES "SupplierPayment"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

