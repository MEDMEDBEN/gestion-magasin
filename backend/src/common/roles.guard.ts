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
import { AccessRequirement, assertAccess } from './user-access';

/// Exigences déclarées sur la route (méthode, sinon classe).
export function routeRequirement(
  reflector: Reflector,
  context: ExecutionContext,
): AccessRequirement {
  const targets = [context.getHandler(), context.getClass()];
  return {
    roles: reflector.getAllAndOverride<RoleCode[]>(ROLES_KEY, targets),
    permissions: reflector.getAllAndOverride<string[]>(PERMISSIONS_KEY, targets),
  };
}

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

    // Accès lu dans le token : pas de requête DB à chaque appel.
    assertAccess(routeRequirement(this.reflector, context), user);
    return true;
  }
}
