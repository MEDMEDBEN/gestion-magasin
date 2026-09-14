import { Module } from '@nestjs/common';
import { ConfigModule } from '@nestjs/config';
import { APP_GUARD } from '@nestjs/core';
import { ThrottlerGuard, ThrottlerModule } from '@nestjs/throttler';
import { AppController } from './app.controller';

import { AuthModule } from './auth/auth.module';
import { ApiContractModule } from './common/api-contract.module';
import { intFromEnv, validateEnv } from './common/env';
import { JwtAccessGuard } from './common/jwt-access.guard';
import { RolesGuard } from './common/roles.guard';
import { PrismaModule } from './prisma/prisma.module';
import { LocationsModule } from './locations/locations.module';
import { ProductsModule } from './products/products.module';
import { SyncModule } from './sync/sync.module';
import { UsersModule } from './users/users.module';

@Module({
  imports: [
    // `validate` : refus de démarrer sur une configuration dangereuse
    // (clé JWT d'exemple ou trop courte, limite non numérique…).
    ConfigModule.forRoot({
      isGlobal: true,
      envFilePath: ['.env'],
      validate: validateEnv,
    }),
    // Limite globale anti-brute-force, PAR IP réelle (voir `configureApp`).
    // /auth/login, /auth/refresh et /auth/change-password sont bridés plus
    // sévèrement au niveau du controller.
    ThrottlerModule.forRoot([
      { ttl: 60_000, limit: () => intFromEnv('API_RATE_LIMIT', 120) },
    ]),
    PrismaModule,
    AuthModule,
    UsersModule,
    ProductsModule,
    LocationsModule,
    SyncModule,
    ApiContractModule,
  ],
  controllers: [AppController],
  providers: [
    // Ordre significatif : on limite le débit, puis on authentifie, puis on autorise.
    // Les guards sont globaux pour qu'aucune route ne puisse être exposée par oubli.
    { provide: APP_GUARD, useClass: ThrottlerGuard },
    { provide: APP_GUARD, useClass: JwtAccessGuard },
    { provide: APP_GUARD, useClass: RolesGuard },
  ],
})
export class AppModule {}
