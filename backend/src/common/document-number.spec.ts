import { localDate, localYear, startOfLocalDay } from './document-number';

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

  /// La borne d'un « aujourd'hui » comparé à un horodatage réel : une vente
  /// encaissée à 00h30 à Alger appartient à la journée qui vient de commencer,
  /// pas à la veille (ce que minuit UTC lui ferait dire).
  it('la journée d’Alger commence une heure AVANT minuit UTC', () => {
    const minuitTrente = new Date('2026-09-22T23:30:00Z'); // 00h30 le 23 à Alger
    expect(localDate(minuitTrente)).toBe('2026-09-23');
    expect(startOfLocalDay(minuitTrente).toISOString()).toBe(
      '2026-09-22T23:00:00.000Z',
    );
    expect(minuitTrente >= startOfLocalDay(minuitTrente)).toBe(true);
  });

  it('en pleine journée, la borne reste le début de CETTE journée', () => {
    expect(
      startOfLocalDay(new Date('2026-09-23T14:00:00Z')).toISOString(),
    ).toBe('2026-09-22T23:00:00.000Z');
  });
});
