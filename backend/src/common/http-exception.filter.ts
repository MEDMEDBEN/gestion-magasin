import {
  ArgumentsHost,
  Catch,
  ExceptionFilter,
  HttpException,
  HttpStatus,
  Logger,
} from '@nestjs/common';
import { Response } from 'express';
import { Prisma } from '../generated/prisma/client';
import { ErrorCode } from './error-codes';

/// Garantit le format d'erreur uniforme `{ statusCode, message, error, code? }`
/// pour TOUTES les réponses en échec (CONVENTIONS.md).
@Catch()
export class HttpExceptionFilter implements ExceptionFilter {
  private readonly logger = new Logger(HttpExceptionFilter.name);

  catch(exception: unknown, host: ArgumentsHost): void {
    const response = host.switchToHttp().getResponse<Response>();

    if (exception instanceof HttpException) {
      const status = exception.getStatus();
      const body = exception.getResponse();
      const payload =
        typeof body === 'object' && body !== null
          ? (body as Record<string, unknown>)
          : { message: body };

      response.status(status).json({
        statusCode: status,
        message: payload.message ?? exception.message,
        error: payload.error ?? HttpStatus[status],
        code: payload.code ?? HttpExceptionFilter.defaultCode(status),
      });
      return;
    }

    // Violation d'unicité levée par la base (deux créations concurrentes du même
    // email, du même code-barres…) : c'est un conflit métier, pas une panne.
    if (
      exception instanceof Prisma.PrismaClientKnownRequestError &&
      exception.code === 'P2002'
    ) {
      response.status(HttpStatus.CONFLICT).json({
        statusCode: HttpStatus.CONFLICT,
        message: 'Cette valeur est déjà utilisée par un autre enregistrement',
        error: HttpStatus[HttpStatus.CONFLICT],
        code: ErrorCode.CONFLICT,
      });
      return;
    }

    // Toute exception non maîtrisée : on logue en interne, on ne fuit rien au client.
    this.logger.error('Exception non gérée', exception as Error);
    response.status(HttpStatus.INTERNAL_SERVER_ERROR).json({
      statusCode: HttpStatus.INTERNAL_SERVER_ERROR,
      message: 'Erreur interne du serveur',
      error: 'Internal Server Error',
    });
  }

  /// Code métier posé quand l'exception n'en porte pas (erreurs du framework).
  private static defaultCode(status: number): ErrorCode | undefined {
    switch (status) {
      // Les erreurs de validation class-validator n'ont pas de code métier.
      case HttpStatus.BAD_REQUEST:
        return ErrorCode.VALIDATION_FAILED;
      // Levée par le ThrottlerGuard.
      case HttpStatus.TOO_MANY_REQUESTS:
        return ErrorCode.RATE_LIMITED;
      default:
        return undefined;
    }
  }
}
