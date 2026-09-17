import { ExecutionContext } from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import {
  AuthenticatedUser,
  IS_PUBLIC_KEY,
  PERMISSIONS_KEY,
  ROLES_KEY,
  RoleCode,
} from './auth.decorators';
import { RolesGuard } from './roles.guard';

function contextWithUser(user?: AuthenticatedUser): ExecutionContext {
  return {
    switchToHttp: () => ({ getRequest: () => ({ user }) }),
    getHandler: () => undefined,
    getClass: () => undefined,
  } as unknown as ExecutionContext;
}

function reflectorReturning(metadata: Record<string, unknown>): Reflector {
  return {
    getAllAndOverride: (key: string) => metadata[key],
  } as unknown as Reflector;
}

const vendeur: AuthenticatedUser = {
  id: 'u1',
  roles: [RoleCode.VENDEUR],
  permissions: ['sale.create'],
  mustChangePassword: false,
};

const admin: AuthenticatedUser = {
  id: 'u2',
  roles: [RoleCode.ADMIN],
  permissions: ['user.manage', 'sale.cancel'],
  mustChangePassword: false,
};

/// Vérifie qu'un guard refuse avec le code métier attendu (correspondance partielle).
function expectRefusal(fn: () => unknown, expectedCode: string): void {
  try {
    fn();
  } catch (error) {
    const response = (
      error as { getResponse: () => { code?: string } }
    ).getResponse();
    expect(response.code).toBe(expectedCode);
    return;
  }
  throw new Error(
    `Refus attendu (${expectedCode}) mais aucune exception n'a été levée`,
  );
}

describe('RolesGuard — matrice de docs/permissions.md', () => {
  it('autorise un rôle listé', () => {
    const guard = new RolesGuard(
      reflectorReturning({ [ROLES_KEY]: [RoleCode.ADMIN, RoleCode.VENDEUR] }),
    );

    expect(guard.canActivate(contextWithUser(vendeur))).toBe(true);
  });

  it('refuse un rôle non listé', () => {
    const guard = new RolesGuard(
      reflectorReturning({ [ROLES_KEY]: [RoleCode.ADMIN] }),
    );

    expectRefusal(
      () => guard.canActivate(contextWithUser(vendeur)),
      'FORBIDDEN_ROLE',
    );
  });

  it('autorise un utilisateur cumulant plusieurs rôles', () => {
    const cumul: AuthenticatedUser = {
      ...vendeur,
      roles: [RoleCode.VENDEUR, RoleCode.MAGASINIER],
    };
    const guard = new RolesGuard(
      reflectorReturning({ [ROLES_KEY]: [RoleCode.MAGASINIER] }),
    );

    expect(guard.canActivate(contextWithUser(cumul))).toBe(true);
  });

  it('REFUSE une route authentifiée sans @Roles (règle 1 : pas de guard = fermé)', () => {
    const guard = new RolesGuard(reflectorReturning({}));

    expectRefusal(
      () => guard.canActivate(contextWithUser(admin)),
      'FORBIDDEN_ROLE',
    );
  });

  it('laisse passer une route @Public', () => {
    const guard = new RolesGuard(reflectorReturning({ [IS_PUBLIC_KEY]: true }));

    expect(guard.canActivate(contextWithUser(undefined))).toBe(true);
  });

  it('refuse une requête sans utilisateur authentifié', () => {
    const guard = new RolesGuard(
      reflectorReturning({ [ROLES_KEY]: [RoleCode.ADMIN] }),
    );

    expect(() => guard.canActivate(contextWithUser(undefined))).toThrow();
  });

  it('exige la permission atomique en plus du rôle', () => {
    const guard = new RolesGuard(
      reflectorReturning({
        [ROLES_KEY]: [RoleCode.ADMIN, RoleCode.VENDEUR],
        [PERMISSIONS_KEY]: ['sale.discount'],
      }),
    );

    // Le vendeur a le bon rôle mais PAS la permission de remise (décision figée).
    expectRefusal(
      () => guard.canActivate(contextWithUser(vendeur)),
      'FORBIDDEN_PERMISSION',
    );
  });

  it('exige TOUTES les permissions demandées', () => {
    const guard = new RolesGuard(
      reflectorReturning({
        [ROLES_KEY]: [RoleCode.ADMIN],
        [PERMISSIONS_KEY]: ['user.manage', 'settings.manage'],
      }),
    );

    expectRefusal(
      () => guard.canActivate(contextWithUser(admin)),
      'FORBIDDEN_PERMISSION',
    );
  });

  it('autorise quand rôle et permissions sont réunis', () => {
    const guard = new RolesGuard(
      reflectorReturning({
        [ROLES_KEY]: [RoleCode.ADMIN],
        [PERMISSIONS_KEY]: ['user.manage'],
      }),
    );

    expect(guard.canActivate(contextWithUser(admin))).toBe(true);
  });
});
