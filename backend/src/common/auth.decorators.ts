import {
  createParamDecorator,
  ExecutionContext,
  SetMetadata,
} from '@nestjs/common';

/// Rôles figés (CLAUDE.md). Le code du rôle en base est identique à ces valeurs.
export enum RoleCode {
  ADMIN = 'ADMIN',
  VENDEUR = 'VENDEUR',
  MAGASINIER = 'MAGASINIER',
}

export const IS_PUBLIC_KEY = 'isPublic';
export const ROLES_KEY = 'roles';
export const PERMISSIONS_KEY = 'permissions';
export const ALLOW_PASSWORD_CHANGE_KEY = 'allowPasswordChange';
export const FRESH_READ_KEY = 'freshRead';

/// Route accessible sans access token (login, refresh). À utiliser avec parcimonie.
export const Public = () => SetMetadata(IS_PUBLIC_KEY, true);

/// Rôle(s) autorisé(s). Un utilisateur cumulant plusieurs rôles passe s'il en a au moins un.
export const Roles = (...roles: RoleCode[]) => SetMetadata(ROLES_KEY, roles);

/// Permission(s) atomique(s) requises, en plus du rôle (docs/permissions.md).
export const RequirePermissions = (...permissions: string[]) =>
  SetMetadata(PERMISSIONS_KEY, permissions);

/// Lecture SENSIBLE : droits relus en base comme pour une écriture (les
/// écritures le sont TOUJOURS, voir `FreshAccessGuard`).
export const RequireFreshAccess = () => SetMetadata(FRESH_READ_KEY, true);

/// Route utilisable même quand `mustChangePassword` est vrai (uniquement change-password / logout).
export const AllowPasswordChange = () =>
  SetMetadata(ALLOW_PASSWORD_CHANGE_KEY, true);

export interface AuthenticatedUser {
  id: string;
  roles: string[];
  permissions: string[];
  mustChangePassword: boolean;
  /// Session (ligne `RefreshToken`) émise avec cet access token. Relue par
  /// `FreshAccessGuard` : une session révoquée ne passe plus les routes sensibles.
  sessionId?: string;
}

/// Injecte l'utilisateur authentifié résolu par le JwtAccessGuard.
export const CurrentUser = createParamDecorator(
  (_data: unknown, ctx: ExecutionContext): AuthenticatedUser =>
    ctx.switchToHttp().getRequest().user,
);
