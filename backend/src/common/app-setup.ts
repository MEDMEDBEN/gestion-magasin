import { json } from 'express';
import { ValidationPipe } from '@nestjs/common';
import { NestExpressApplication } from '@nestjs/platform-express';
import { intFromEnv } from './env';
import { HttpExceptionFilter } from './http-exception.filter';

/// Configuration HTTP de l'application, partagée par `main.ts` ET par les tests
/// d'intégration : les tests éprouvent exactement ce qui tourne en production.
export function configureApp(app: NestExpressApplication): void {
  // En production, Traefik est le seul pair TCP du backend : sans ceci, `req.ip`
  // vaut toujours l'IP du proxy — tout Internet partagerait le même compteur
  // anti-brute-force et l'audit tracerait l'IP de Traefik au lieu du client.
  // Un NOMBRE de sauts de confiance, jamais `true` : sinon un client pourrait
  // choisir son IP en forgeant `X-Forwarded-For`. 0 (défaut) = pas de proxy.
  app.set('trust proxy', intFromEnv('TRUST_PROXY_HOPS', 0, 0));

  // Rien ne doit annoncer la pile technique, et le corps JSON est borné
  // EXPLICITEMENT (ne pas dépendre du défaut d'Express).
  app.getHttpAdapter().getInstance().disable('x-powered-by');
  app.use(json({ limit: '128kb' }));
  app.use(
    (
      _req: unknown,
      res: { setHeader: (k: string, v: string) => void },
      next: () => void,
    ) => {
      res.setHeader('X-Content-Type-Options', 'nosniff');
      res.setHeader('Referrer-Policy', 'no-referrer');
      res.setHeader('X-Frame-Options', 'DENY');
      next();
    },
  );

  app.setGlobalPrefix('api');
  app.useGlobalFilters(new HttpExceptionFilter());
  app.useGlobalPipes(
    new ValidationPipe({
      whitelist: true, // supprime les champs non déclarés dans le DTO
      forbidNonWhitelisted: true, // ... et refuse la requête si on en envoie
      transform: true,
      transformOptions: { enableImplicitConversion: false },
    }),
  );
}
