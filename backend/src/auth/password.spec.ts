import { hashPassword, verifyPassword } from './password';

/// Tests unitaires du hachage de mot de passe — priorité absolue (sécurité).
describe('password — hachage argon2', () => {
  it('produit un hash argon2id qui ne contient jamais le mot de passe en clair', async () => {
    const hash = await hashPassword('MotDePasse123!');

    expect(hash.startsWith('$argon2id$')).toBe(true);
    expect(hash).not.toContain('MotDePasse123!');
  });

  it('vérifie un mot de passe correct', async () => {
    const hash = await hashPassword('MotDePasse123!');

    await expect(verifyPassword(hash, 'MotDePasse123!')).resolves.toBe(true);
  });

  it('rejette un mot de passe incorrect', async () => {
    const hash = await hashPassword('MotDePasse123!');

    await expect(verifyPassword(hash, 'MauvaisMotDePasse')).resolves.toBe(
      false,
    );
  });

  it('sale le hash : deux hachages du même mot de passe diffèrent', async () => {
    const [a, b] = await Promise.all([
      hashPassword('MemeMotDePasse'),
      hashPassword('MemeMotDePasse'),
    ]);

    expect(a).not.toEqual(b);
    await expect(verifyPassword(a, 'MemeMotDePasse')).resolves.toBe(true);
    await expect(verifyPassword(b, 'MemeMotDePasse')).resolves.toBe(true);
  });

  it('renvoie false au lieu de jeter si le hash est corrompu', async () => {
    await expect(verifyPassword('pas-un-hash', 'peu-importe')).resolves.toBe(
      false,
    );
  });
});
