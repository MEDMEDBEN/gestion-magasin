import { AuthenticatedUser, RoleCode } from '../common/auth.decorators';
import { PermissionCode } from '../common/permissions';
import { Prisma } from '../generated/prisma/client';
import { AuditAction, OperationType } from '../generated/prisma/enums';

/// Contexte fourni au handler : la transaction EST celle du moteur — tout ce que le
/// handler écrit est annulé si la mutation est rejetée (contrat de sync §4.5).
export interface SyncMutationContext {
  tx: Prisma.TransactionClient;
  user: AuthenticatedUser;
  deviceId: string;
  clientMutationId: string;
  deviceTimestamp: Date;
}

export interface SyncApplyResult {
  /// Entité créée/modifiée — mémorisée pour renvoyer le même résultat sur retry.
  entityId: string;
  /// État serveur renvoyé au client pour réconcilier son affichage.
  serverState?: Record<string, string>;
  /// Valeur d'audit lisible (état appliqué) ; à défaut, le payload brut du client.
  auditNewValue?: Prisma.InputJsonValue;
}

/// Un type d'opération synchronisable = un handler. Les features P0 en ajoutent un
/// chacune (vente, réception, transfert, inventaire…) sans toucher au moteur.
///
/// Un `operationType` sans handler n'est PAS rejeté : il repart `NON_TRAITEE` et reste
/// dans la file du client — un rejet mémorisé serait définitif alors que la feature
/// arrive dans une version ultérieure.
export interface SyncMutationHandler<TPayload extends object = object> {
  readonly operationType: OperationType;

  /// Rôle(s) ET permission(s) exigés — EXACTEMENT ce qu'exige la route en ligne
  /// équivalente (contrat §4.2). Les deux sont nécessaires : la matrice de
  /// `docs/permissions.md` combine rôle et permission, et un membre peut se voir accorder
  /// une permission à la carte sans avoir le rôle. Sans le contrôle de rôle ici, le sync
  /// serait un contournement de la matrice.
  readonly requiredRoles: readonly RoleCode[];
  readonly requiredPermissions: readonly PermissionCode[];

  /// Trace écrite dans `AuditLog` par le moteur, dans la même transaction (contrat §4.4).
  readonly auditEntityType: string;
  readonly auditAction: AuditAction;

  /// Valide la forme du payload. Doit lever une `BusinessException` si non conforme.
  validate(payload: unknown): Promise<TPayload>;

  /// Applique la mutation. Lever une `BusinessException` = REJET (rien n'est appliqué).
  apply(
    payload: TPayload,
    context: SyncMutationContext,
  ): Promise<SyncApplyResult>;
}

/// Jeton d'injection multi-fournisseurs : le module de sync assemble la liste.
export const SYNC_MUTATION_HANDLERS = Symbol('SYNC_MUTATION_HANDLERS');
