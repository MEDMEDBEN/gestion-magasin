import { HttpStatus } from '@nestjs/common';
import type { UserGetPayload } from '../generated/prisma/models';
import { BusinessException } from './business.exception';
import { ErrorCode } from './error-codes';

/// Relations chargées pour connaître l'accès d'un compte (rôles + permissions).
/// Une seule définition, partagée par l'auth, la gestion des comptes et les guards.
export const USER_ACCESS_INCLUDE = {
  roles: { include: { permissions: { select: { code: true } } } },
  permissions: { select: { code: true } },
} as const;

/// Utilisateur tel que chargé avec `USER_ACCESS_INCLUDE`.
export type UserWithAccess = UserGetPayload<{ include: typeof USER_ACCESS_INCLUDE }>;

/// Permissions EFFECTIVES : celles des rôles + celles accordées à la carte.
export function resolvePermissions(user: UserWithAccess): string[] {
  const fromRoles = user.roles.flatMap((role) =>
    role.permissions.map((permission) => permission.code),
  );
  const direct = user.permissions.map((permission) => permission.code);
  return [...new Set([...fromRoles, ...direct])].sort();
}

/// Exigences d'une route (`@Roles` + `@RequirePermissions`).
export interface AccessRequirement {
  roles?: readonly string[];
  permissions?: readonly string[];
}

/// Applique la matrice de `docs/permissions.md` à un accès donné — rôle requis
/// (au moins un), PUIS toutes les permissions atomiques requises.
///
/// Partagée par `RolesGuard` (accès lu dans le token) et `FreshAccessGuard`
/// (accès relu en base) : une seule règle, deux sources.
export function assertAccess(
  requirement: AccessRequirement,
  access: { roles: readonly string[]; permissions: readonly string[] },
): void {
  const requiredRoles = requirement.roles ?? [];
  if (requiredRoles.length === 0) {
    throw new BusinessException(
      ErrorCode.FORBIDDEN_ROLE,
      'Route sans @Roles explicite — accès refusé par défaut',
      HttpStatus.FORBIDDEN,
    );
  }
  if (!requiredRoles.some((role) => access.roles.includes(role))) {
    throw new BusinessException(
      ErrorCode.FORBIDDEN_ROLE,
      'Rôle insuffisant pour cette action',
      HttpStatus.FORBIDDEN,
    );
  }

  const missing = (requirement.permissions ?? []).filter(
    (permission) => !access.permissions.includes(permission),
  );
  if (missing.length > 0) {
    throw new BusinessException(
      ErrorCode.FORBIDDEN_PERMISSION,
      `Permission manquante : ${missing.join(', ')}`,
      HttpStatus.FORBIDDEN,
    );
  }
}
