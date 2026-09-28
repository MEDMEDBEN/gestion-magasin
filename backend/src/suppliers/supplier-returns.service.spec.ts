import { Prisma } from '../generated/prisma/client';
import { ReceivedLot, valueReturn } from './supplier-returns.service';

const d = (v: string | number) => new Prisma.Decimal(v);
const lot = (qty: string, unitPriceHt: number, ttc: number): ReceivedLot => ({
  receivedQuantity: d(qty),
  unitPriceHt,
  lineTotalTtc: ttc,
  taxRate: d(19),
});

describe('valueReturn (valorisation d’un retour fournisseur)', () => {
  // Du plus récent au plus ancien : 1 u. à 1 000 DA, puis 100 u. à 100 DA.
  const lots = [lot('1', 100000, 119000), lot('100', 10000, 1190000)];

  it('consomme les lots au prix de CHACUN, jamais au dernier prix', () => {
    const all = valueReturn(lots, d(0), d(101))!;
    expect(all.lineTotalTtc).toBe(119000 + 1190000);
    expect(all.lineTotalHt).toBe(100000 + 1000000);
    // 2 unités : la récente (1 000) + une ancienne (100).
    expect(valueReturn(lots, d(0), d(2))!.lineTotalTtc).toBe(119000 + 11900);
  });

  it('au-delà du reçu non renvoyé : null', () => {
    expect(valueReturn(lots, d(0), d('101.001'))).toBeNull();
    expect(valueReturn(lots, d(100), d(2))).toBeNull();
    expect(valueReturn(lots, d(0), d(0))).toBeNull();
  });

  it('retours partiels successifs : rendent EXACTEMENT le TTC reçu', () => {
    // 3 u. pour 100,00 TTC : un tiers ne tombe pas juste.
    const odd = [lot('3', 2801, 10000)];
    const parts = ['1', '1', '1'].reduce(
      (acc, q) => {
        const v = valueReturn(odd, acc.gone, d(q))!;
        return { gone: acc.gone.plus(q), ttc: acc.ttc + v.lineTotalTtc };
      },
      { gone: d(0), ttc: 0 },
    );
    expect(parts.ttc).toBe(10000);
  });
});
