import {
  CanActivate,
  ExecutionContext,
  HttpStatus,
  Injectable,
} from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import { PrismaService } from '../prisma/prisma.service';
import { AuthenticatedUser } from './auth.decorators';
import { BusinessException } from './business.exception';
import { ErrorCode } from './error-codes';
import { routeRequirement } from './roles.guard';
import {
  assertAccess,
  resolvePermissions,
  USER_ACCESS_INCLUDE,
} from './user-access';

/// Revérifie l'accès contre l'état COURANT du compte en base, et non contre le
/// token. S'ajoute (`@UseGuards`) aux guards globaux, sur les routes rares et
/// sensibles uniquement.
///
/// Pourquoi : l'access token dénormalise rôles et permissions pour 15 min. Sur la
/// gestion des comptes, cette fenêtre permettrait à un admin qu'on vient de
/// désactiver ou de rétrograder de se rétablir lui-même — définitivement (audit I4).
@Injectable()
export class FreshAccessGuard implements CanActivate {
  constructor(
    private readonly reflector: Reflector,
    private readonly prisma: PrismaService,
  ) {}

  async canActivate(context: ExecutionContext): Promise<boolean> {
    const request = context.switchToHttp().getRequest<{ user?: AuthenticatedUser }>();
    const tokenUser = request.user;
    if (!tokenUser) {
      throw new BusinessException(
        ErrorCode.FORBIDDEN_ROLE,
        'Utilisateur non authentifié',
        HttpStatus.UNAUTHORIZED,
      );
    }

    const current = await this.prisma.user.findUnique({
      where: { id: tokenUser.id },
      include: USER_ACCESS_INCLUDE,
    });
    if (!current || !current.isActive) {
      throw new BusinessException(
        ErrorCode.ACCOUNT_DISABLED,
        'Ce compte est désactivé',
        HttpStatus.FORBIDDEN,
      );
    }

    const access = {
      roles: current.roles.map((role) => role.code),
      permissions: resolvePermissions(current),
    };
    assertAccess(routeRequirement(this.reflector, context), access);

    // Le handler travaille sur l'accès réel, pas sur celui du token.
    request.user = { ...tokenUser, ...access };
    return true;
  }
}
