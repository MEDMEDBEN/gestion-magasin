import { ExecutionContext } from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import { JwtService } from '@nestjs/jwt';
import {
  ALLOW_PASSWORD_CHANGE_KEY,
  IS_PUBLIC_KEY,
} from './auth.decorators';
import { AccessTokenPayload, JwtAccessGuard } from './jwt-access.guard';

const SECRET = 'secret-de-test-uniquement';

function contextWith(
  headers: Record<string, string>,
): ExecutionContext & { request: Record<string, unknown> } {
  const request: Record<string, unknown> = { headers };
  return {
    request,
    switchToHttp: () => ({ getRequest: () => request }),
    getHandler: () => undefined,
    getClass: () => undefined,
  } as unknown as ExecutionContext & { request: Record<string, unknown> };
}

/// Reflector simulé : renvoie la métadonnée demandée pour la route testée.
function reflectorReturning(metadata: Record<string, unknown>): Reflector {
  return {
    getAllAndOverride: (key: string) => metadata[key],
  } as unknown as Reflector;
}

describe('JwtAccessGuard — émission et vérification du JWT', () => {
  const jwt = new JwtService({ secret: SECRET });
  const payload: AccessTokenPayload = {
    sub: '00000000-0000-7000-8000-000000000001',
    sid: '00000000-0000-7000-8000-0000000000aa',
    roles: ['VENDEUR'],
    permissions: ['sale.create'],
    mustChangePassword: false,
  };

  it('accepte un token valide et pose req.user', async () => {
    const guard = new JwtAccessGuard(jwt, reflectorReturning({}));
    const token = await jwt.signAsync(payload, { expiresIn: 900 });
    const ctx = contextWith({ authorization: `Bearer ${token}` });

    await expect(guard.canActivate(ctx)).resolves.toBe(true);
    expect(ctx.request.user).toMatchObject({
      id: payload.sub,
      roles: ['VENDEUR'],
      permissions: ['sale.create'],
    });
  });

  it('refuse une requête sans en-tête Authorization', async () => {
    const guard = new JwtAccessGuard(jwt, reflectorReturning({}));

    await expect(guard.canActivate(contextWith({}))).rejects.toMatchObject({
      response: { code: 'ACCESS_TOKEN_MISSING' },
    });
  });

  it('refuse un token signé avec un autre secret', async () => {
    const guard = new JwtAccessGuard(jwt, reflectorReturning({}));
    const forged = await new JwtService({ secret: 'mauvais-secret' }).signAsync(payload);

    await expect(
      guard.canActivate(contextWith({ authorization: `Bearer ${forged}` })),
    ).rejects.toMatchObject({ response: { code: 'ACCESS_TOKEN_INVALID' } });
  });

  it('refuse un token expiré', async () => {
    const guard = new JwtAccessGuard(jwt, reflectorReturning({}));
    const expired = await jwt.signAsync(payload, { expiresIn: -10 });

    await expect(
      guard.canActivate(contextWith({ authorization: `Bearer ${expired}` })),
    ).rejects.toMatchObject({ response: { code: 'ACCESS_TOKEN_INVALID' } });
  });

  it('laisse passer une route @Public sans token', async () => {
    const guard = new JwtAccessGuard(
      jwt,
      reflectorReturning({ [IS_PUBLIC_KEY]: true }),
    );

    await expect(guard.canActivate(contextWith({}))).resolves.toBe(true);
  });

  it('bloque toute route si mustChangePassword est vrai', async () => {
    const guard = new JwtAccessGuard(jwt, reflectorReturning({}));
    const token = await jwt.signAsync({ ...payload, mustChangePassword: true });

    await expect(
      guard.canActivate(contextWith({ authorization: `Bearer ${token}` })),
    ).rejects.toMatchObject({ response: { code: 'PASSWORD_CHANGE_REQUIRED' } });
  });

  it('autorise malgré mustChangePassword la route marquée @AllowPasswordChange', async () => {
    const guard = new JwtAccessGuard(
      jwt,
      reflectorReturning({ [ALLOW_PASSWORD_CHANGE_KEY]: true }),
    );
    const token = await jwt.signAsync({ ...payload, mustChangePassword: true });

    await expect(
      guard.canActivate(contextWith({ authorization: `Bearer ${token}` })),
    ).resolves.toBe(true);
  });
});
