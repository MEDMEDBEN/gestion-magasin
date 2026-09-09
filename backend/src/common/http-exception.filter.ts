import {
  ArgumentsHost,
  Catch,
  ExceptionFilter,
  HttpException,
  HttpStatus,
  Logger,
} from '@nestjs/common';
import { Response } from 'express';
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
        // Les erreurs de validation class-validator n'ont pas de code métier : on en pose un.
        code:
          payload.code ??
          (status === HttpStatus.BAD_REQUEST
            ? ErrorCode.VALIDATION_FAILED
            : undefined),
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
}
