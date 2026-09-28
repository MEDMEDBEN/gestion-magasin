-- AlterTable
ALTER TABLE "CustomerPayment" ADD COLUMN     "saleReturnId" UUID;

-- CreateIndex
CREATE UNIQUE INDEX "CustomerPayment_saleReturnId_key" ON "CustomerPayment"("saleReturnId");

-- AddForeignKey
ALTER TABLE "CustomerPayment" ADD CONSTRAINT "CustomerPayment_saleReturnId_fkey" FOREIGN KEY ("saleReturnId") REFERENCES "SaleReturn"("id") ON DELETE SET NULL ON UPDATE CASCADE;