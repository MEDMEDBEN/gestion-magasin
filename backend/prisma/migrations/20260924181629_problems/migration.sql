-- CreateEnum
CREATE TYPE "ProblemCategory" AS ENUM ('STOCK_INCORRECT', 'PRODUIT_MANQUANT', 'PRODUIT_ENDOMMAGE', 'PROBLEME_INFORMATIQUE', 'PROBLEME_MATERIEL', 'AUTRE');

-- CreateEnum
CREATE TYPE "ProblemStatus" AS ENUM ('OUVERT', 'EN_COURS', 'RESOLU', 'FERME');

-- CreateTable
CREATE TABLE "Problem" (
    "id" UUID NOT NULL,
    "title" TEXT NOT NULL,
    "category" "ProblemCategory" NOT NULL,
    "description" TEXT NOT NULL,
    "priority" "Priority" NOT NULL DEFAULT 'NORMALE',
    "status" "ProblemStatus" NOT NULL DEFAULT 'OUVERT',
    "photoKey" TEXT,
    "productId" UUID,
    "locationId" UUID,
    "reportedById" UUID NOT NULL,
    "assignedToId" UUID,
    "resolution" TEXT,
    "resolvedAt" TIMESTAMP(3),
    "closedAt" TIMESTAMP(3),
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "Problem_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE INDEX "Problem_status_createdAt_idx" ON "Problem"("status", "createdAt");

-- CreateIndex
CREATE INDEX "Problem_reportedById_idx" ON "Problem"("reportedById");

-- AddForeignKey
ALTER TABLE "Problem" ADD CONSTRAINT "Problem_reportedById_fkey" FOREIGN KEY ("reportedById") REFERENCES "User"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "Problem" ADD CONSTRAINT "Problem_assignedToId_fkey" FOREIGN KEY ("assignedToId") REFERENCES "User"("id") ON DELETE SET NULL ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "Problem" ADD CONSTRAINT "Problem_productId_fkey" FOREIGN KEY ("productId") REFERENCES "Product"("id") ON DELETE SET NULL ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "Problem" ADD CONSTRAINT "Problem_locationId_fkey" FOREIGN KEY ("locationId") REFERENCES "Location"("id") ON DELETE SET NULL ON UPDATE CASCADE;

