import { parseSort } from './pagination.dto';

/// `?sort=` : liste blanche de champs (trier sur une colonne sensible permettrait
/// d'en deviner le contenu par comparaisons successives).
describe('parseSort', () => {
  const allowed = ['fullName', 'createdAt'] as const;

  it('traduit un tri autorisé en orderBy Prisma', () => {
    expect(parseSort('fullName:asc', allowed, { createdAt: 'desc' })).toEqual({
      fullName: 'asc',
    });
  });

  it('retombe sur le tri par défaut sans paramètre', () => {
    expect(parseSort(undefined, allowed, { createdAt: 'desc' })).toEqual({
      createdAt: 'desc',
    });
  });

  it('refuse un champ hors liste blanche', () => {
    expect(() =>
      parseSort('passwordHash:asc', allowed, { createdAt: 'desc' }),
    ).toThrow(/Tri impossible/);
  });
});
