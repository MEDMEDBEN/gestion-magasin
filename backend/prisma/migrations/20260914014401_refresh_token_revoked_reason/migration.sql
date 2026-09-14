-- CreateEnum
CREATE TYPE "RefreshTokenRevokedReason" AS ENUM ('ROTATION', 'LOGOUT', 'SUPERSEDED', 'REVOKED');

-- AlterTable
ALTER TABLE "RefreshToken" ADD COLUMN     "revokedReason" "RefreshTokenRevokedReason";
