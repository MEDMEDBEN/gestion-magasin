import {
  CanActivate,
  ExecutionContext,
  HttpStatus,
  Injectable,
} from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import { JwtService } from '@nestjs/jwt';
import { Request } from 'express';
import {
  ALLOW_PASSWORD_CHANGE_KEY,
  AuthenticatedUser,
  IS_PUBLIC_KEY,
} from './auth.decorators';
import { BusinessException } from './business.exception';
import { ErrorCode } from './error-codes';

/// Charge utile de l'access token. Rôles et permissions y sont dénormalisés :
/// pas de requête DB à chaque appel, au prix d'une fenêtre de 15 min avant qu'une
/// révocation de permission prenne effet (durée de vie volontairement courte).
export interface AccessTokenPayload {
  sub: string;
  /// Id de la session (`RefreshToken`) émise en même temps que ce token.
  sid: string;
  roles: string[];
  permissions: string[];
  mustChangePassword: boolean;
}

@Injectable()
export class JwtAccessGuard implements CanActivate {
  constructor(
    private readonly jwt: JwtService,
    private readonly reflector: Reflector,
  ) {}

  async canActivate(context: ExecutionContext): Promise<boolean> {
    const isPublic = this.reflector.getAllAndOverride<boolean>(IS_PUBLIC_KEY, [
      context.getHandler(),
      context.getClass(),
    ]);
    if (isPublic) return true;

    const request = context.switchToHttp().getRequest<Request>();
    const header = request.headers.authorization;
    if (!header?.startsWith('Bearer ')) {
      throw new BusinessException(
        ErrorCode.ACCESS_TOKEN_MISSING,
        'Access token manquant',
        HttpStatus.UNAUTHORIZED,
      );
    }

    let payload: AccessTokenPayload;
    try {
      payload = await this.jwt.verifyAsync<AccessTokenPayload>(
        header.slice('Bearer '.length),
      );
    } catch {
      throw new BusinessException(
        ErrorCode.ACCESS_TOKEN_INVALID,
        'Access token invalide ou expiré',
        HttpStatus.UNAUTHORIZED,
      );
    }

    const user: AuthenticatedUser = {
      id: payload.sub,
      roles: payload.roles ?? [],
      permissions: payload.permissions ?? [],
      mustChangePassword: payload.mustChangePassword ?? false,
      sessionId: payload.sid,
    };
    (request as Request & { user: AuthenticatedUser }).user = user;

    // Première connexion : tout est verrouillé tant que le mot de passe n'a pas été changé.
    const allowPasswordChange = this.reflector.getAllAndOverride<boolean>(
      ALLOW_PASSWORD_CHANGE_KEY,
      [context.getHandler(), context.getClass()],
    );
    if (user.mustChangePassword && !allowPasswordChange) {
      throw new BusinessException(
        ErrorCode.PASSWORD_CHANGE_REQUIRED,
        'Changement de mot de passe obligatoire avant toute autre action',
        HttpStatus.FORBIDDEN,
      );
    }

    return true;
  }
}
