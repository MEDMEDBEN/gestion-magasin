-- AlterTable
ALTER TABLE "CashMovement" ADD COLUMN     "clientMutationId" UUID;

-- CreateIndex
CREATE UNIQUE INDEX "CashMovement_clientMutationId_key" ON "CashMovement"("clientMutationId");

