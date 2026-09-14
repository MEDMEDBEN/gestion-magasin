-- CreateEnum
CREATE TYPE "StockLossStatus" AS ENUM ('EN_ATTENTE', 'VALIDEE', 'REFUSEE');

-- CreateTable
CREATE TABLE "StockLossDeclaration" (
    "id" UUID NOT NULL,
    "productId" UUID NOT NULL,
    "locationId" UUID NOT NULL,
    "quantity" DECIMAL(14,3) NOT NULL,
    "comment" TEXT,
    "status" "StockLossStatus" NOT NULL DEFAULT 'EN_ATTENTE',
    "declaredById" UUID NOT NULL,
    "decidedById" UUID,
    "decidedAt" TIMESTAMP(3),
    "decisionNote" TEXT,
    "movementId" UUID,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "StockLossDeclaration_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE UNIQUE INDEX "StockLossDeclaration_movementId_key" ON "StockLossDeclaration"("movementId");

-- CreateIndex
CREATE INDEX "StockLossDeclaration_status_createdAt_idx" ON "StockLossDeclaration"("status", "createdAt");

-- CreateIndex
CREATE INDEX "StockLossDeclaration_productId_idx" ON "StockLossDeclaration"("productId");

-- AddForeignKey
ALTER TABLE "StockLossDeclaration" ADD CONSTRAINT "StockLossDeclaration_productId_fkey" FOREIGN KEY ("productId") REFERENCES "Product"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "StockLossDeclaration" ADD CONSTRAINT "StockLossDeclaration_locationId_fkey" FOREIGN KEY ("locationId") REFERENCES "Location"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "StockLossDeclaration" ADD CONSTRAINT "StockLossDeclaration_declaredById_fkey" FOREIGN KEY ("declaredById") REFERENCES "User"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "StockLossDeclaration" ADD CONSTRAINT "StockLossDeclaration_decidedById_fkey" FOREIGN KEY ("decidedById") REFERENCES "User"("id") ON DELETE SET NULL ON UPDATE CASCADE;
