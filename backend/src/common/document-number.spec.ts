import { localDate, localYear } from './document-number';

describe('dates locales (Africa/Algiers, UTC+1)', () => {
  it('le 31/12 à 23h30 UTC est déjà le 1er janvier à Alger', () => {
    const instant = new Date('2026-12-31T23:30:00Z');
    expect(localYear(instant)).toBe(2027);
    expect(localDate(instant)).toBe('2027-01-01');
  });

  it('le 31/12 à 22h59 UTC est encore l’année en cours', () => {
    const instant = new Date('2026-12-31T22:59:00Z');
    expect(localYear(instant)).toBe(2026);
    expect(localDate(instant)).toBe('2026-12-31');
  });
});
