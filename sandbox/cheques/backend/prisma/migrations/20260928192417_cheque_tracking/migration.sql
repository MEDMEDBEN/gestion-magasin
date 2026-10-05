-- CreateEnum
CREATE TYPE "ChequeStatus" AS ENUM ('EN_PORTEFEUILLE', 'ENCAISSE', 'REJETE');

-- AlterTable
ALTER TABLE "CustomerPayment" ADD COLUMN     "chequeBank" TEXT,
ADD COLUMN     "chequeDueDate" TIMESTAMP(3),
ADD COLUMN     "chequeNumber" TEXT,
ADD COLUMN     "chequeStatus" "ChequeStatus",
ADD COLUMN     "chequeStatusAt" TIMESTAMP(3),
ADD COLUMN     "chequeStatusById" UUID;

-- AlterTable
ALTER TABLE "SupplierPayment" ADD COLUMN     "chequeBank" TEXT,
ADD COLUMN     "chequeDueDate" TIMESTAMP(3),
ADD COLUMN     "chequeNumber" TEXT,
ADD COLUMN     "chequeStatus" "ChequeStatus",
ADD COLUMN     "chequeStatusAt" TIMESTAMP(3),
ADD COLUMN     "chequeStatusById" UUID;

-- CreateIndex
CREATE INDEX "CustomerPayment_chequeStatus_idx" ON "CustomerPayment"("chequeStatus");

-- CreateIndex
CREATE INDEX "SupplierPayment_chequeStatus_idx" ON "SupplierPayment"("chequeStatus");
