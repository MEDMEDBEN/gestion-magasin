import {
  CanActivate,
  ExecutionContext,
  HttpStatus,
  Injectable,
} from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import { PrismaService } from '../prisma/prisma.service';
import {
  ALLOW_PASSWORD_CHANGE_KEY,
  AuthenticatedUser,
  FRESH_READ_KEY,
  IS_PUBLIC_KEY,
} from './auth.decorators';
import { BusinessException } from './business.exception';
import { ErrorCode } from './error-codes';
import { routeRequirement } from './roles.guard';
import {
  assertAccess,
  resolvePermissions,
  USER_ACCESS_INCLUDE,
} from './user-access';

/// Revérifie l'accès contre l'état COURANT du compte en base, et non contre le
/// token. Guard GLOBAL unique (après JWT et rôles) : il s'applique à TOUTE
/// écriture authentifiée (POST, PUT, PATCH, DELETE) — argent, stock, catalogue,
/// comptes, sync — sans décorateur à ne pas oublier sur une nouvelle route.
/// Une lecture sensible s'y soumet avec `@RequireFreshAccess()`.
///
/// Pourquoi : l'access token dénormalise rôles et permissions pour 15 min. Sur la
/// gestion des comptes, cette fenêtre permettrait à un admin qu'on vient de
/// désactiver ou de rétrograder de se rétablir lui-même — définitivement (audit I4),
/// ou à un voleur d'identifiants de créer un admin de secours APRÈS que la
/// victime a révoqué ses sessions ou changé son mot de passe (contre-audit N1).
///
/// Relu en base : compte actif, pas de mot de passe temporaire imposé, session
/// (`sid` du token) ni révoquée ni expirée, puis rôles et permissions.
@Injectable()
export class FreshAccessGuard implements CanActivate {
  constructor(
    private readonly reflector: Reflector,
    private readonly prisma: PrismaService,
  ) {}

  async canActivate(context: ExecutionContext): Promise<boolean> {
    const handlers = [context.getHandler(), context.getClass()];
    const request = context
      .switchToHttp()
      .getRequest<{ user?: AuthenticatedUser; method: string }>();
    if (this.reflector.getAllAndOverride<boolean>(IS_PUBLIC_KEY, handlers)) {
      return true;
    }
    const isWrite = !['GET', 'HEAD', 'OPTIONS'].includes(request.method);
    const freshRead = this.reflector.getAllAndOverride<boolean>(
      FRESH_READ_KEY,
      handlers,
    );
    if (!isWrite && !freshRead) return true;

    const tokenUser = request.user;
    if (!tokenUser) {
      throw new BusinessException(
        ErrorCode.FORBIDDEN_ROLE,
        'Utilisateur non authentifié',
        HttpStatus.UNAUTHORIZED,
      );
    }

    const [current, session] = await Promise.all([
      this.prisma.user.findUnique({
        where: { id: tokenUser.id },
        include: USER_ACCESS_INCLUDE,
      }),
      tokenUser.sessionId
        ? this.prisma.refreshToken.findUnique({
            where: { id: tokenUser.sessionId },
            select: { userId: true, revokedAt: true, expiresAt: true },
          })
        : null,
    ]);
    if (!current || !current.isActive) {
      throw new BusinessException(
        ErrorCode.ACCOUNT_DISABLED,
        'Ce compte est désactivé',
        HttpStatus.FORBIDDEN,
      );
    }

    // Session fermée (révocation, reset, changement de mot de passe, rotation)
    // ou token antérieur à la liaison token ↔ session : 401 — le client rejoue
    // avec son token courant, ou revient au login si sa session est finie.
    const sessionAlive =
      session !== null &&
      session.userId === current.id &&
      session.revokedAt === null &&
      session.expiresAt.getTime() > Date.now();
    if (!sessionAlive) {
      throw new BusinessException(
        ErrorCode.ACCESS_TOKEN_INVALID,
        'Session fermée — reconnexion ou renouvellement nécessaire',
        HttpStatus.UNAUTHORIZED,
      );
    }

    // Un reset par l'admin pose `mustChangePassword` en base : il s'applique
    // sans attendre le prochain token.
    if (
      current.mustChangePassword &&
      !this.reflector.getAllAndOverride<boolean>(
        ALLOW_PASSWORD_CHANGE_KEY,
        handlers,
      )
    ) {
      throw new BusinessException(
        ErrorCode.PASSWORD_CHANGE_REQUIRED,
        'Changement de mot de passe obligatoire avant toute autre action',
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
