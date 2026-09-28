-- CreateTable
CREATE TABLE "StoreSettings" (
    "id" INTEGER NOT NULL DEFAULT 1,
    "name" TEXT,
    "address" TEXT,
    "phone" TEXT,
    "nif" TEXT,
    "rc" TEXT,
    "nis" TEXT,
    "ai" TEXT,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "StoreSettings_pkey" PRIMARY KEY ("id")
);
