import { HttpStatus } from '@nestjs/common';
import { plainToInstance } from 'class-transformer';
import { validate, ValidationError } from 'class-validator';
import { BusinessException } from './business.exception';
import { ErrorCode } from './error-codes';

type Constructor<T> = new () => T;

function flatten(errors: ValidationError[], parent = ''): string[] {
  return errors.flatMap((error) => {
    const path = parent ? `${parent}.${error.property}` : error.property;
    const own = Object.values(error.constraints ?? {}).map(
      (message) => `${path} : ${message}`,
    );
    return [...own, ...flatten(error.children ?? [], path)];
  });
}

/// Valide un payload JSON imbriqué (le `ValidationPipe` global ne descend pas dans un
/// champ `Json` libre). Utilisé par les handlers de sync : chaque type d'opération
/// déclare son DTO et le payload est refusé s'il n'y correspond pas exactement.
export async function validatePayload<T extends object>(
  cls: Constructor<T>,
  payload: unknown,
): Promise<T> {
  if (
    typeof payload !== 'object' ||
    payload === null ||
    Array.isArray(payload)
  ) {
    throw new BusinessException(
      ErrorCode.VALIDATION_FAILED,
      'Payload invalide : un objet JSON est attendu',
      HttpStatus.UNPROCESSABLE_ENTITY,
    );
  }

  const instance = plainToInstance(cls, payload, {
    enableImplicitConversion: false,
  });
  const errors = await validate(instance, {
    whitelist: true,
    forbidNonWhitelisted: true,
  });
  if (errors.length > 0) {
    throw new BusinessException(
      ErrorCode.VALIDATION_FAILED,
      `Payload invalide — ${flatten(errors).join(' ; ')}`,
      HttpStatus.UNPROCESSABLE_ENTITY,
    );
  }
  return instance;
}
