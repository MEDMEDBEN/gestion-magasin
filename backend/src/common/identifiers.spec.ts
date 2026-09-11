import {
  isEmailIdentifier,
  normalizeEmail,
  normalizeIdentifier,
  normalizePhone,
  PHONE_PATTERN,
} from './identifiers';

/// Audit M2 : un même identifiant saisi différemment doit désigner le même compte.
describe('identifiants de connexion', () => {
  it('normalise un email : espaces et casse', () => {
    expect(normalizeEmail('  Karim@Magasin.DZ ')).toBe('karim@magasin.dz');
  });

  it('normalise un téléphone : ponctuation de saisie retirée', () => {
    expect(normalizePhone('+213 (0)555 12-34.56')).toBe('+2130555123456');
  });

  it('distingue email et téléphone sans ambiguïté', () => {
    expect(isEmailIdentifier('a@b.dz')).toBe(true);
    expect(isEmailIdentifier('0555123456')).toBe(false);
    expect(normalizeIdentifier(' A@B.DZ ')).toBe('a@b.dz');
    expect(normalizeIdentifier('0555 12 34 56')).toBe('0555123456');
  });

  it('valide un téléphone : 6 à 15 chiffres, « + » en tête seulement', () => {
    expect(PHONE_PATTERN.test('+213555123456')).toBe(true);
    expect(PHONE_PATTERN.test('0555123456')).toBe(true);
    expect(PHONE_PATTERN.test('12345')).toBe(false);
    expect(PHONE_PATTERN.test('05551234a6')).toBe(false);
    expect(PHONE_PATTERN.test('0555+123456')).toBe(false);
  });

  it('laisse passer une valeur non textuelle telle quelle (la validation la refusera)', () => {
    expect(normalizeEmail(42)).toBe(42);
    expect(normalizePhone(null)).toBeNull();
  });
});
