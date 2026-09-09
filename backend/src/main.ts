import { ValidationPipe } from '@nestjs/common';
import { NestFactory } from '@nestjs/core';
import { DocumentBuilder, SwaggerModule } from '@nestjs/swagger';
import { AppModule } from './app.module';
import { HttpExceptionFilter } from './common/http-exception.filter';

async function bootstrap(): Promise<void> {
  const app = await NestFactory.create(AppModule);

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

  const config = new DocumentBuilder()
    .setTitle('Gestion magasin — API')
    .setDescription(
      'Contrat REST du logiciel de gestion magasin + dépôt (matériel électrique).\n\n' +
        '- Montants : entiers en **centimes de DA**.\n' +
        '- Quantités : **décimales** (chaîne, ex. `"12.500"`).\n' +
        '- Erreurs : `{ statusCode, message, error, code? }` — le client se base sur `code`.\n' +
        '- Listes : `{ data, meta: { page, limit, total } }`.',
    )
    .setVersion('0.1.0')
    .addBearerAuth({ type: 'http', scheme: 'bearer', bearerFormat: 'JWT' })
    .build();

  // La doc expose toute la surface de l'API : jamais servie en production.
  if (process.env.NODE_ENV !== 'production') {
    SwaggerModule.setup('docs', app, SwaggerModule.createDocument(app, config), {
      swaggerOptions: { persistAuthorization: true },
    });
  }

  await app.listen(process.env.PORT ?? 3000);
}

void bootstrap();
