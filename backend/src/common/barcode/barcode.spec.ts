import { gs1CheckDigit, internalBarcode, normalizeBarcode } from './barcode';

describe('codes-barres (règle 15)', () => {
  it('calcule la clé GS1 d’un EAN-13 réel', () => {
    // 4006381333931 : exemple officiel GS1.
    expect(gs1CheckDigit('400638133393')).toBe(1);
    // EAN-8 : 96385074.
    expect(gs1CheckDigit('9638507')).toBe(4);
  });

  it('génère un EAN-13 interne préfixé 20, clé valide', () => {
    const code = internalBarcode(42);
    expect(code).toMatch(/^20\d{11}$/);
    expect(code.slice(2, 12)).toBe('0000000042');
    expect(normalizeBarcode(code)).toBe(code);
  });

  it('refuse une séquence qui déborderait 10 chiffres', () => {
    expect(() => internalBarcode(10_000_000_000)).toThrow();
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
