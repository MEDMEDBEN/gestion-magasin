import { Prisma } from '../generated/prisma/client';
import { AuditAction } from '../generated/prisma/enums';

/// Qui agit, et depuis où — indispensable pour tracer une action sensible (spec §24).
export interface ActorContext {
  /// `null` quand l'action n'a pas d'auteur authentifié (ex. détection d'un
  /// refresh token rejoué : c'est le serveur qui réagit).
  userId: string | null;
  ipAddress?: string | null;
}

export interface AuditEntry {
  action: AuditAction;
  entityType: string;
  entityId: string;
  oldValue?: Prisma.InputJsonValue;
  newValue?: Prisma.InputJsonValue;
}

/// Écrit une entrée du journal d'audit.
///
/// Toujours appelée AVEC la transaction de la mutation tracée (règles 3 et 7 de
/// CLAUDE.md) : une modification sans trace devient impossible par construction,
/// et une trace sans modification aussi. Ne jamais y placer de secret : le journal
/// est consultable par l'admin.
export async function writeAudit(
  db: Prisma.TransactionClient,
  actor: ActorContext,
  entry: AuditEntry,
): Promise<void> {
  await db.auditLog.create({
    data: {
      userId: actor.userId,
      action: entry.action,
      entityType: entry.entityType,
      entityId: entry.entityId,
      oldValue: entry.oldValue,
      newValue: entry.newValue,
      ipAddress: actor.ipAddress ?? null,
    },
  });
}
