import { intFromEnv, validateEnv } from './env';

/// Audit M8 : refuser de démarrer sur une configuration dangereuse.
describe('validateEnv — configuration refusée au démarrage', () => {
  const valid = {
    DATABASE_URL: 'postgresql://dev:dev@localhost:5432/db',
    JWT_ACCESS_SECRET: 'x'.repeat(48),
  };

  it('accepte une configuration saine', () => {
    expect(validateEnv({ ...valid, TRUST_PROXY_HOPS: '0', AUTH_LOGIN_LIMIT: '10' })).toMatchObject(valid);
  });

  it('refuse la clé JWT d’exemple de .env.example', () => {
    expect(() =>
      validateEnv({ ...valid, JWT_ACCESS_SECRET: 'CHANGER_CETTE_CLE_ALEATOIRE' }),
    ).toThrow(/valeur d’exemple/);
  });

  it('refuse une clé JWT de moins de 32 octets', () => {
    expect(() => validateEnv({ ...valid, JWT_ACCESS_SECRET: 'trop-courte' })).toThrow(/trop court/);
  });

  it('refuse une clé JWT absente et une base absente, en listant tout', () => {
    expect(() => validateEnv({})).toThrow(/DATABASE_URL[\s\S]*JWT_ACCESS_SECRET/);
  });

  it('refuse une limite anti-brute-force non numérique (sinon NaN la désactiverait)', () => {
    expect(() => validateEnv({ ...valid, AUTH_LOGIN_LIMIT: 'dix' })).toThrow(/AUTH_LOGIN_LIMIT/);
    expect(() => validateEnv({ ...valid, AUTH_LOGIN_LIMIT: '0' })).toThrow(/AUTH_LOGIN_LIMIT/);
  });

  it('refuse un nombre de sauts de proxy négatif ou décimal', () => {
    expect(() => validateEnv({ ...valid, TRUST_PROXY_HOPS: '-1' })).toThrow(/TRUST_PROXY_HOPS/);
    expect(() => validateEnv({ ...valid, TRUST_PROXY_HOPS: '1.5' })).toThrow(/TRUST_PROXY_HOPS/);
  });
});

describe('intFromEnv — lu au moment de l’appel', () => {
  afterEach(() => delete process.env.E2E_TEST_LIMIT);

  it('retombe sur la valeur par défaut si absente', () => {
    expect(intFromEnv('E2E_TEST_LIMIT', 7)).toBe(7);
  });

  it('lit la valeur courante', () => {
    process.env.E2E_TEST_LIMIT = '42';
    expect(intFromEnv('E2E_TEST_LIMIT', 7)).toBe(42);
  });

  it('lève une erreur sur une valeur invalide au lieu de l’ignorer', () => {
    process.env.E2E_TEST_LIMIT = 'beaucoup';
    expect(() => intFromEnv('E2E_TEST_LIMIT', 7)).toThrow(/E2E_TEST_LIMIT/);
  });
});
