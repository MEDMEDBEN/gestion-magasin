import { HttpStatus } from '@nestjs/common';
import { BusinessException } from './business.exception';
import { ErrorCode } from './error-codes';

const DATE_ONLY = /^(\d{4})-(\d{2})-(\d{2})$/;
const DATE_TIME =
  /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}(\.\d{1,3})?)?(Z|[+-]\d{2}:\d{2})$/;

/// Date reçue d'un client : `AAAA-MM-JJ` ou ISO 8601 complet, rien d'autre.
/// `@IsISO8601` laisse passer des formes (semaine, jour de l'année) que `Date`
/// ne lit pas, et `new Date('2026-02-30')` devient le 2 mars : une date
/// illisible ou inexistante est une 400 (saisie invalide), jamais une 500 ni une date fausse.
export function parseApiDate(raw: string, field: string): Date {
  const invalid = () =>
    new BusinessException(
      ErrorCode.VALIDATION_FAILED,
      `${field} : date invalide (attendu AAAA-MM-JJ ou ISO 8601 complet)`,
      HttpStatus.BAD_REQUEST,
    );
  const day = DATE_ONLY.exec(raw);
  if (!day && !DATE_TIME.test(raw)) throw invalid();
  const date = new Date(raw);
  const year = date.getUTCFullYear();
  if (Number.isNaN(date.getTime()) || year < 2000 || year > 9999) {
    throw invalid();
  }
  // Jour inexistant (30 février) : la date relue doit être celle saisie.
  if (day && date.toISOString().slice(0, 10) !== raw) throw invalid();
  return date;
}
