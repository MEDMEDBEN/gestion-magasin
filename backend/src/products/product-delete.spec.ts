import { ProductsService } from './products.service';

// Effacement définitif (2026-11-15) : seulement SANS historique (règle 7).
describe('effacement d’un produit', () => {
  const product = {
    id: 'p1',
    name: 'Câble',
    sku: 'C',
    barcode: 'B',
    imageUrl: null,
  };
  const build = (movements: number, problems = 0) => {
    const tx = {
      $executeRaw: jest.fn().mockResolvedValue(0),
      product: {
        findUnique: jest.fn().mockResolvedValue(product),
        delete: jest.fn().mockResolvedValue(product),
      },
      stockMovement: {
        count: jest.fn().mockResolvedValue(movements),
        deleteMany: jest.fn().mockResolvedValue({ count: 1 }),
      },
      problem: { count: jest.fn().mockResolvedValue(problems) },
      auditLog: { create: jest.fn().mockResolvedValue({}) },
    };
    const prisma = {
      $transaction: (fn: (t: typeof tx) => unknown) => fn(tx),
    };
    const storage = { remove: jest.fn() };
    const service = new ProductsService(
      prisma as never,
      {} as never,
      storage as never,
      {} as never,
    );
    return { tx, service };
  };

  it('avec des mouvements (ventes, achats…) : refus 409, rien effacé', async () => {
    const { tx, service } = build(2);
    await expect(service.remove('p1', { userId: 'a' })).rejects.toMatchObject({
      status: 409,
    });
    expect(tx.product.delete).not.toHaveBeenCalled();
  });

  it('lié à un signalement : refus 409 (le lien ne doit pas disparaître)', async () => {
    const { tx, service } = build(0, 1);
    await expect(service.remove('p1', { userId: 'a' })).rejects.toMatchObject({
      status: 409,
    });
    expect(tx.product.delete).not.toHaveBeenCalled();
  });

  it('sans historique : effacé avec son stock initial, et tracé', async () => {
    const { tx, service } = build(0);
    await service.remove('p1', { userId: 'a' });
    expect(tx.stockMovement.deleteMany).toHaveBeenCalledWith({
      where: { productId: 'p1', operationType: 'PRODUCT', operationId: 'p1' },
    });
    expect(tx.product.delete).toHaveBeenCalledWith({ where: { id: 'p1' } });
    expect(tx.auditLog.create).toHaveBeenCalled();
  });
});
