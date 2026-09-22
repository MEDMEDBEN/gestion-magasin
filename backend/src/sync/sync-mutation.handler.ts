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
  /// Valeur d'audit lisible (état appliqué). OBLIGATOIRE : un handler qui
  /// l'oublierait ferait tomber le payload BRUT du client dans le journal — la
  /// P0 #12 va en ajouter une dizaine (audit sécurité du 2026-09-21).
  auditNewValue: Prisma.InputJsonValue;
  /// Action tracée quand elle dépend du contenu (caisse : ouverture = CREATE,
  /// clôture = VALIDATE). Par défaut, `auditAction` du handler.
  auditAction?: AuditAction;
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
  ///
  /// Si l'opération a une route EN LIGNE qui enregistre la même clé
  /// (`clientMutationId`), `apply` DOIT d'abord reconnaître l'entité déjà créée
  /// par cette route et la rendre telle quelle (même contenu) : l'app met en file,
  /// sous la même clé, une écriture dont la réponse en ligne s'est perdue. Sans
  /// cela : doublon, ou collision renvoyée « réessayer » à chaque cycle.
  apply(
    payload: TPayload,
    context: SyncMutationContext,
  ): Promise<SyncApplyResult>;

  /// L'entité de cette clé existe-t-elle déjà (créée par la route EN LIGNE) ?
  /// Sert au moteur quand `apply` heurte une contrainte d'unicité : si oui,
  /// c'est une course avec la même opération en ligne — « réessayer » (le
  /// prochain cycle la reconnaîtra), pas un rejet définitif. Obligatoire dès
  /// que la route en ligne enregistre la clé.
  /// Limité à l'AUTEUR : une clé d'un autre compte ne peut pas faire boucler
  /// une file en « réessayer ».
  existsForKey?(clientMutationId: string, userId: string): Promise<boolean>;
}

/// Au-delà, l'instant de l'appareil n'est plus cru. Même valeur que
/// `AppConfig.maxOfflineDuration`, mais pas la même mesure (l'app mesure l'âge
/// de sa file au moment de saisir).
const MAX_OFFLINE_MS = 72 * 3600 * 1000;

/// Instant d'une opération faite hors-ligne : celui de l'appareil s'il est
/// plausible — ni dans le futur, ni plus ancien que la durée hors-ligne permise
/// —, sinon celui de la synchronisation. Borne l'antidatage par un appel direct.
export function plausibleDeviceTime(deviceTimestamp: Date, now = new Date()) {
  const age = now.getTime() - deviceTimestamp.getTime();
  return age >= 0 && age <= MAX_OFFLINE_MS ? deviceTimestamp : now;
}

/// Jeton d'injection multi-fournisseurs : le module de sync assemble la liste.
export const SYNC_MUTATION_HANDLERS = Symbol('SYNC_MUTATION_HANDLERS');
