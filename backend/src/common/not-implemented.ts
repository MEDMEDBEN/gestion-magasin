import { HttpStatus } from '@nestjs/common';
import { BusinessException } from './business.exception';
import { ErrorCode } from './error-codes';

/// Marque un endpoint dont le CONTRAT est figé (route, DTO, guards, doc OpenAPI)
/// mais dont l'implémentation arrive avec sa feature (voir l'ordre dans docs/plan.md).
/// Renvoie 501 avec un code métier stable, jamais une 404 trompeuse.
export function notImplemented(feature: string): never {
  throw new BusinessException(
    ErrorCode.NOT_IMPLEMENTED,
    `Contrat figé, implémentation à venir avec la feature « ${feature} »`,
    HttpStatus.NOT_IMPLEMENTED,
  );
}
