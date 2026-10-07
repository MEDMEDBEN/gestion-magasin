-- Suppression d'un compte = archivage (l'historique le désigne toujours).
ALTER TABLE "User" ADD COLUMN "deletedAt" TIMESTAMP(3);
