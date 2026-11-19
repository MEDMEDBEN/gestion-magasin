import { DirectPurchaseHandler } from './direct-purchase.handler';

// La clé du payload DOIT être celle de la mutation (comme les autres handlers).
describe('synchro de l’achat direct', () => {
  it('clé du payload différente de la mutation : refusée', async () => {
    const handler = new DirectPurchaseHandler({} as never, {} as never);
    await expect(
      handler.apply(
        {
          clientMutationId: '0192a0b2-7c1d-7e3f-8a4b-5c6d7e8f9a0b',
          supplierId: 's1',
          lines: [],
        },
        { clientMutationId: '0192a0b2-7c1d-7e3f-8a4b-000000000000' } as never,
      ),
    ).rejects.toMatchObject({ status: 422 });
  });
});
