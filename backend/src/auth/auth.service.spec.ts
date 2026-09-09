import { AuthService } from './auth.service';

/// Tests unitaires du hachage de mot de passe — priorité absolue (sécurité).
describe('AuthService — hachage argon2', () => {
  it('produit un hash argon2id qui ne contient jamais le mot de passe en clair', async () => {
    const hash = await AuthService.hashPassword('MotDePasse123!');

    expect(hash.startsWith('$argon2id$')).toBe(true);
    expect(hash).not.toContain('MotDePasse123!');
  });

  it('vérifie un mot de passe correct', async () => {
    const hash = await AuthService.hashPassword('MotDePasse123!');

    await expect(AuthService.verifyPassword(hash, 'MotDePasse123!')).resolves.toBe(true);
  });

  it('rejette un mot de passe incorrect', async () => {
    const hash = await AuthService.hashPassword('MotDePasse123!');

    await expect(AuthService.verifyPassword(hash, 'MauvaisMotDePasse')).resolves.toBe(
      false,
    );
  });

  it('sale le hash : deux hachages du même mot de passe diffèrent', async () => {
    const [a, b] = await Promise.all([
      AuthService.hashPassword('MemeMotDePasse'),
      AuthService.hashPassword('MemeMotDePasse'),
    ]);

    expect(a).not.toEqual(b);
    await expect(AuthService.verifyPassword(a, 'MemeMotDePasse')).resolves.toBe(true);
    await expect(AuthService.verifyPassword(b, 'MemeMotDePasse')).resolves.toBe(true);
  });

  it('renvoie false au lieu de jeter si le hash est corrompu', async () => {
    await expect(AuthService.verifyPassword('pas-un-hash', 'peu-importe')).resolves.toBe(
      false,
    );
  });
});
