import {
  ArgumentsHost,
  BadRequestException,
  HttpException,
  HttpStatus,
  Logger,
} from '@nestjs/common';
import { Prisma } from '../generated/prisma/client';
import { BusinessException } from './business.exception';
import { ErrorCode } from './error-codes';
import { HttpExceptionFilter } from './http-exception.filter';

/// Format d'erreur uniforme `{ statusCode, message, error, code? }` (CONVENTIONS.md) :
/// le client se branche sur `code`, il doit donc être présent et stable.
describe('HttpExceptionFilter', () => {
  const run = (exception: unknown) => {
    const json = jest.fn();
    const status = jest.fn(() => ({ json }));
    const host = {
      switchToHttp: () => ({ getResponse: () => ({ status }) }),
    } as unknown as ArgumentsHost;

    jest.spyOn(Logger.prototype, 'error').mockImplementation(() => undefined);
    new HttpExceptionFilter().catch(exception, host);
    return { status: (status.mock.calls[0] as unknown[])[0], body: json.mock.calls[0][0] };
  };

  afterEach(() => jest.restoreAllMocks());

  it('conserve le code d’une exception métier', () => {
    const { status, body } = run(
      new BusinessException(ErrorCode.LAST_ACTIVE_ADMIN, 'Dernier admin', HttpStatus.CONFLICT),
    );

    expect(status).toBe(409);
    expect(body).toMatchObject({ statusCode: 409, code: 'LAST_ACTIVE_ADMIN' });
  });

  it('pose VALIDATION_FAILED sur une erreur de validation', () => {
    expect(run(new BadRequestException(['email invalide'])).body.code).toBe('VALIDATION_FAILED');
  });

  it('pose RATE_LIMITED sur un 429 du throttler', () => {
    const { status, body } = run(new HttpException('Too Many Requests', HttpStatus.TOO_MANY_REQUESTS));

    expect(status).toBe(429);
    expect(body.code).toBe('RATE_LIMITED');
  });

  it('traduit une violation d’unicité Prisma (P2002) en conflit 409, pas en 500', () => {
    const exception = new Prisma.PrismaClientKnownRequestError('Unique constraint failed', {
      code: 'P2002',
      clientVersion: 'test',
    });

    const { status, body } = run(exception);

    expect(status).toBe(409);
    expect(body.code).toBe('CONFLICT');
  });

  it('ne fuit rien d’une exception inattendue', () => {
    const { status, body } = run(new Error('SELECT secret FROM "User"'));

    expect(status).toBe(500);
    expect(JSON.stringify(body)).not.toContain('secret');
  });
});
