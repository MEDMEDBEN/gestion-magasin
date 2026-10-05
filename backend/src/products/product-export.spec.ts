import { PERMISSIONS } from '../common/permissions';
import { renderExport } from '../common/export/export';
import { ProductsService } from './products.service';

/// Export des produits sélectionnés (2026-10-05) : le prix d'achat n'y figure
/// QUE pour qui le voit (`cost.read`). Aujourd'hui les trois rôles l'ont : la
/// branche « sans coût » n'est prouvable qu'ici (audit sécurité 2026-10-06).
describe('export de la sélection : prix d’achat selon cost.read', () => {
  const product = {
    id: 'p1',
    sku: 'CAB-3G25',
    name: 'Câble 3G2,5',
    barcode: '2000000000015',
    unit: 'METRE',
    category: { name: 'Câbles' },
    prices: [{ priceTierId: 't1', priceHt: 145000 }],
    lastPurchasePriceHt: 98765,
    minThreshold: { toString: () => '10.000' },
    isActive: true,
  };
  const prisma = {
    product: { findMany: jest.fn().mockResolvedValue([product]) },
    priceTier: {
      findFirst: jest.fn().mockResolvedValue({ id: 't1', name: 'Détail' }),
    },
  };
  const service = new ProductsService(
    prisma as never,
    undefined as never,
    undefined as never,
    undefined as never,
  );
  const viewer = (permissions: string[]) =>
    ({ permissions }) as unknown as Parameters<
      ProductsService['exportSelection']
    >[1];

  async function csvFor(permissions: string[]): Promise<string> {
    const doc = await service.exportSelection(
      { format: 'csv', ids: ['p1'] },
      viewer(permissions),
    );
    return (await renderExport(doc, 'csv')).buffer.toString('utf8');
  }

  it('sans cost.read : ni colonne, ni valeur du prix d’achat', async () => {
    const csv = await csvFor([
      PERMISSIONS.PRODUCT_READ,
      PERMISSIONS.PRICE_READ,
    ]);
    expect(csv).not.toContain('Prix d’achat');
    expect(csv).not.toContain('987,65');
    expect(csv).toContain('1450,00');
  });

  it('avec cost.read : la colonne et la valeur', async () => {
    const csv = await csvFor([
      PERMISSIONS.PRODUCT_READ,
      PERMISSIONS.PRICE_READ,
      PERMISSIONS.COST_READ,
    ]);
    expect(csv).toContain('Prix d’achat');
    expect(csv).toContain('987,65');
  });
});
