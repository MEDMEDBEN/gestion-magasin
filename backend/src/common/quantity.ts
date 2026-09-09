import { HttpStatus } from '@nestjs/common';
import { Prisma } from '../generated/prisma/client';
import { BusinessException } from './business.exception';
import { ErrorCode } from './error-codes';

/// Quantités : `Decimal(14,3)` en base (CLAUDE.md règle 10 — certains produits se vendent
/// au mètre). Elles transitent en CHAÎNE pour ne jamais passer par un flottant.
/// Ce fichier est le SEUL point de conversion chaîne ↔ Decimal du backend.
export const QUANTITY_SCALE = 3;

/// 11 chiffres avant la virgule, 3 après — la borne exacte de `Decimal(14,3)`.
const QUANTITY_PATTERN = /^-?\d{1,11}(\.\d{1,3})?$/;

/// Convertit une quantité reçue du client. Lève une erreur métier (jamais une 500)
/// si la valeur n'est pas une décimale représentable telle quelle en base.
export function parseQuantity(raw: string, field = 'quantity'): Prisma.Decimal {
  if (typeof raw !== 'string' || !QUANTITY_PATTERN.test(raw)) {
    throw new BusinessException(
      ErrorCode.VALIDATION_FAILED,
      `${field} : quantité décimale invalide (max 11 chiffres, ${QUANTITY_SCALE} décimales), reçu « ${String(raw)} »`,
      HttpStatus.UNPROCESSABLE_ENTITY,
    );
  }
  return new Prisma.Decimal(raw);
}

/// Format de transport unique : toujours 3 décimales (`"12.500"`).
export function formatQuantity(
  value: Prisma.Decimal | string | number | null | undefined,
): string {
  return new Prisma.Decimal(value ?? 0).toFixed(QUANTITY_SCALE);
}
