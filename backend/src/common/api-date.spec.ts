import { parseApiDate } from './api-date';

describe('parseApiDate', () => {
  it('accepte AAAA-MM-JJ et l’ISO complet', () => {
    expect(parseApiDate('2026-09-16', 'd').toISOString()).toBe(
      '2026-09-16T00:00:00.000Z',
    );
    expect(parseApiDate('2026-09-16T10:30:00+01:00', 'd').toISOString()).toBe(
      '2026-09-16T09:30:00.000Z',
    );
  });

  it.each(['2026-W05', '2026-045', '20260101', '2026-02-30', '0001-01-01', ''])(
    'refuse « %s » (jamais une date fausse ni une 500)',
    (raw) => {
      expect(() => parseApiDate(raw, 'd')).toThrow('date invalide');
    },
  );
});
