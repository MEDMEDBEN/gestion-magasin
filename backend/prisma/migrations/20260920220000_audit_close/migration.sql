-- Clôture d'un reliquat : action propre dans le journal d'audit, pour ne pas la
-- confondre avec une annulation (additif).
ALTER TYPE "AuditAction" ADD VALUE IF NOT EXISTS 'CLOSE';
