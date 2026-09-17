import { NestExpressApplication } from '@nestjs/platform-express';
import { Test } from '@nestjs/testing';
import { AppModule } from '../../src/app.module';
import { hashPassword } from '../../src/auth/password';
import { RoleCode } from '../../src/common/auth.decorators';
import { configureApp } from '../../src/common/app-setup';
import { PrismaService } from '../../src/prisma/prisma.service';

export interface E2eApp {
  app: NestExpressApplication;
  prisma: PrismaService;
  server: ReturnType<NestExpressApplication['getHttpServer']>;
}

/// Application de test configurée EXACTEMENT comme en production (`configureApp`) :
/// préfixe, filtre d'erreurs, validation stricte, `trust proxy`.
export async function createE2eApp(): Promise<E2eApp> {
  const moduleRef = await Test.createTestingModule({
    imports: [AppModule],
  }).compile();
  const app = moduleRef.createNestApplication<NestExpressApplication>();
  configureApp(app);
  await app.init();
  return { app, prisma: app.get(PrismaService), server: app.getHttpServer() };
}

/// Crée un compte directement en base (mot de passe déjà changé par défaut).
export async function createTestUser(
  prisma: PrismaService,
  params: {
    email: string;
    password: string;
    roles: RoleCode[];
    fullName?: string;
    mustChangePassword?: boolean;
    isActive?: boolean;
  },
): Promise<{ id: string }> {
  return prisma.user.create({
    data: {
      email: params.email,
      fullName: params.fullName ?? `E2E ${params.roles.join('+')}`,
      passwordHash: await hashPassword(params.password),
      mustChangePassword: params.mustChangePassword ?? false,
      isActive: params.isActive ?? true,
      roles: { connect: params.roles.map((code) => ({ code })) },
    },
    select: { id: true },
  });
}

/// Fait échouer l'écriture d'AUDIT de la PROCHAINE transaction interactive, à
/// l'intérieur de la vraie transaction PostgreSQL : les écritures déjà faites
/// dans cette transaction (compte modifié, sessions révoquées…) doivent alors
/// être annulées. C'est la preuve réelle de l'atomicité (règles 3 et 7) — un
/// refus levé AVANT la transaction ne prouverait rien.
export function failAuditInNextTransaction(
  prisma: PrismaService,
): jest.SpyInstance {
  const original = prisma.$transaction.bind(prisma) as (
    fn: (tx: unknown) => Promise<unknown>,
  ) => Promise<unknown>;

  return jest.spyOn(prisma, '$transaction').mockImplementationOnce(((
    fn: (tx: unknown) => Promise<unknown>,
  ) =>
    original((tx) =>
      fn(
        new Proxy(tx as object, {
          get(target, property, receiver) {
            if (property === 'auditLog') {
              return {
                create: () =>
                  Promise.reject(
                    new Error('Échec simulé de l’écriture d’audit'),
                  ),
              };
            }
            return Reflect.get(target, property, receiver);
          },
        }),
      ),
    )) as never);
}
