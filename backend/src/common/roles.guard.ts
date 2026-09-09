import {
  CanActivate,
  ExecutionContext,
  HttpStatus,
  Injectable,
} from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import {
  AuthenticatedUser,
  IS_PUBLIC_KEY,
  PERMISSIONS_KEY,
  ROLES_KEY,
  RoleCode,
} from './auth.decorators';
import { BusinessException } from './business.exception';
import { ErrorCode } from './error-codes';

/// Applique la matrice de `docs/permissions.md`.
///
/// Règle 1 de CLAUDE.md — « chaque endpoint a un guard de rôle explicite » : une route
/// authentifiée SANS `@Roles(...)` est REFUSÉE. Oublier le décorateur ferme la route au
/// lieu de l'ouvrir à tout le monde.
@Injectable()
export class RolesGuard implements CanActivate {
  constructor(private readonly reflector: Reflector) {}

  canActivate(context: ExecutionContext): boolean {
    const isPublic = this.reflector.getAllAndOverride<boolean>(IS_PUBLIC_KEY, [
      context.getHandler(),
      context.getClass(),
    ]);
    if (isPublic) return true;

    const user = context.switchToHttp().getRequest().user as
      | AuthenticatedUser
      | undefined;
    if (!user) {
      throw new BusinessException(
        ErrorCode.FORBIDDEN_ROLE,
        'Utilisateur non authentifié',
        HttpStatus.UNAUTHORIZED,
      );
    }

    const requiredRoles = this.reflector.getAllAndOverride<RoleCode[]>(
      ROLES_KEY,
      [context.getHandler(), context.getClass()],
    );
    if (!requiredRoles || requiredRoles.length === 0) {
      throw new BusinessException(
        ErrorCode.FORBIDDEN_ROLE,
        'Route sans @Roles explicite — accès refusé par défaut',
        HttpStatus.FORBIDDEN,
      );
    }
    if (!requiredRoles.some((role) => user.roles.includes(role))) {
      throw new BusinessException(
        ErrorCode.FORBIDDEN_ROLE,
        'Rôle insuffisant pour cette action',
        HttpStatus.FORBIDDEN,
      );
    }

    // Permissions atomiques : exigées TOUTES, en plus du rôle.
    const requiredPermissions = this.reflector.getAllAndOverride<string[]>(
      PERMISSIONS_KEY,
      [context.getHandler(), context.getClass()],
    );
    if (requiredPermissions?.length) {
      const missing = requiredPermissions.filter(
        (permission) => !user.permissions.includes(permission),
      );
      if (missing.length > 0) {
        throw new BusinessException(
          ErrorCode.FORBIDDEN_PERMISSION,
          `Permission manquante : ${missing.join(', ')}`,
          HttpStatus.FORBIDDEN,
        );
      }
    }

    return true;
  }
}
