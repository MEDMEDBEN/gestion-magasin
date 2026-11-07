import {
  gs1CheckDigit,
  internalBarcode,
  normalizeBarcode,
  symbology,
} from './barcode';

describe('codes-barres (règle 15)', () => {
  it('calcule la clé GS1 d’un EAN-13 réel', () => {
    // 4006381333931 : exemple officiel GS1.
    expect(gs1CheckDigit('400638133393')).toBe(1);
    // EAN-8 : 96385074.
    expect(gs1CheckDigit('9638507')).toBe(4);
  });

  // EAN-8 depuis le 2026-11-07 : un code court.
  it('génère un EAN-8 interne préfixé 2, clé valide', () => {
    const code = internalBarcode(42);
    expect(code).toMatch(/^2\d{7}$/);
    expect(code.slice(1, 7)).toBe('000042');
    expect(normalizeBarcode(code)).toBe(code);
    expect(symbology(code)).toBe('ean8');
    // Un ancien code interne EAN-13 reste lu et imprimé en EAN-13.
    expect(symbology('2000000000015')).toBe('ean13');
  });

  it('refuse une séquence qui déborderait 6 chiffres', () => {
    expect(() => internalBarcode(1_000_000)).toThrow();
  });

  it('accepte un GTIN correct et un code alphanumérique, espaces retirés', () => {
    expect(normalizeBarcode(' 4006381333931 ')).toBe('4006381333931');
    expect(normalizeBarcode('LEG-406771')).toBe('LEG-406771');
  });

  it('refuse un GTIN à la clé fausse (code mal lu) et un code vide', () => {
    expect(() => normalizeBarcode('4006381333932')).toThrow(/clé de contrôle/);
    expect(() => normalizeBarcode('   ')).toThrow(/invalide/);
    expect(() => normalizeBarcode('AB CD')).toThrow(/invalide/);
  });
});
