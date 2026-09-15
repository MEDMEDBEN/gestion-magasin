import { StockService } from './stock.service';

describe('StockService.visibleLocations', () => {
  it('sans stock.read.warehouse, seul le stock du MAGASIN est visible', () => {
    expect(
      StockService.visibleLocations({ permissions: ['stock.read.store'] }),
    ).toEqual({
      location: { type: 'MAGASIN' },
    });
  });

  it('avec stock.read.warehouse, aucun filtre', () => {
    expect(
      StockService.visibleLocations({
        permissions: ['stock.read.store', 'stock.read.warehouse'],
      }),
    ).toEqual({});
  });
});
