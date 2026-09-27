import { HttpStatus } from '@nestjs/common';
import { toBuffer } from 'bwip-js';
import { BusinessException } from '../business.exception';
import { ErrorCode } from '../error-codes';

/// Préfixe GS1 « usage interne » (20-29) : jamais porté par un produit fabricant,
/// donc un code interne ne peut pas entrer en conflit avec un vrai code scanné.
export const INTERNAL_BARCODE_PREFIX = '20';

const GTIN_LENGTHS = [8, 12, 13, 14];

/// Codes acceptés : caractères imprimables ASCII sans espace (EAN/UPC, Code128,
/// Code39…), 64 max.
const BARCODE_PATTERN = /^[\x21-\x7E]{1,64}$/;

/// Clé de contrôle GS1 (modulo 10, poids 3/1 en partant de la droite) des
/// chiffres fournis SANS leur clé.
export function gs1CheckDigit(digits: string): number {
  let sum = 0;
  for (let i = 0; i < digits.length; i++) {
    const digit = Number(digits[digits.length - 1 - i]);
    sum += i % 2 === 0 ? digit * 3 : digit;
  }
  return (10 - (sum % 10)) % 10;
}

/// EAN-13 interne : `20` + séquence sur 10 chiffres + clé.
export function internalBarcode(sequence: bigint | number): string {
  const body = INTERNAL_BARCODE_PREFIX + String(sequence).padStart(10, '0');
  if (body.length !== 12) {
    throw new Error(`Séquence de code-barres interne épuisée (${sequence})`);
  }
  return body + gs1CheckDigit(body);
}

/// Normalise et contrôle un code saisi (scan ou clavier). Un code purement
/// numérique à la longueur d'un GTIN doit avoir une clé juste : une douchette
/// qui lit mal produit sinon un doublon silencieux du vrai produit.
export function normalizeBarcode(raw: string): string {
  const code = raw.trim();
  if (!BARCODE_PATTERN.test(code)) {
    throw new BusinessException(
      ErrorCode.VALIDATION_FAILED,
      'Code-barres invalide : 1 à 64 caractères, sans espace',
      HttpStatus.UNPROCESSABLE_ENTITY,
    );
  }
  if (/^\d+$/.test(code) && GTIN_LENGTHS.includes(code.length)) {
    const expected = gs1CheckDigit(code.slice(0, -1));
    if (Number(code[code.length - 1]) !== expected) {
      throw new BusinessException(
        ErrorCode.VALIDATION_FAILED,
        'Code-barres invalide : la clé de contrôle ne correspond pas (code mal lu ?)',
        HttpStatus.UNPROCESSABLE_ENTITY,
      );
    }
  }
  return code;
}

/// Image PNG d'un code-barres, pour une étiquette imprimée (CONVENTIONS.md :
/// `bwip-js`, centralisé ici). Un EAN-13 à clé juste — code interne ou code
/// fabricant — s'imprime en EAN-13 ; tout autre code en Code128, qui encode
/// n'importe quel code accepté par `normalizeBarcode`. Le code en clair est
/// imprimé sous les barres : une douchette défaillante n'arrête pas la caisse.
export async function barcodePng(code: string): Promise<Buffer> {
  const ean13 =
    /^\d{13}$/.test(code) &&
    Number(code[12]) === gs1CheckDigit(code.slice(0, 12));
  return toBuffer({
    bcid: ean13 ? 'ean13' : 'code128',
    text: code,
    scale: 3,
    height: 10,
    includetext: true,
    textxalign: 'center',
  });
}
