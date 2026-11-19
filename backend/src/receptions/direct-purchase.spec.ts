import { DirectPurchaseService } from './direct-purchase';

// Achat direct (2026-11-19) : une réception par lieu, le paiement avec la
// DERNIÈRE, « en total » posé au dépôt et marqué à répartir.
describe('achat direct', () => {
  const build = () => {
    const calls: Record<string, unknown>[] = [];
    const tx = {
      location: {
        findFirst: jest.fn(({ where }: { where: { type: string } }) =>
          Promise.resolve({ id: where.type === 'MAGASIN' ? 'mag' : 'dep' }),
        ),
      },
      product: { updateMany: jest.fn().mockResolvedValue({ count: 1 }) },
    };
    const receptions = {
      createInTx: jest.fn((_tx: unknown, dto: Record<string, unknown>) => {
        calls.push(dto);
        return Promise.resolve({
          id: `r${calls.length}`,
          number: `REC-${calls.length}`,
        });
      }),
    };
    const service = new DirectPurchaseService({} as never, receptions as never);
    return { tx, calls, service };
  };
  const user = { id: 'a', roles: ['ADMIN'], permissions: [] } as never;
  const key = '0192a0b2-7c1d-7e3f-8a4b-5c6d7e8f9a0b';

  it('magasin + dépôt + en total : deux réceptions, paiement sur la dernière', async () => {
    const { tx, calls, service } = build();
    await service.createInTx(
      tx as never,
      {
        clientMutationId: key,
        supplierId: 's1',
        paidAmount: 5000,
        lines: [
          { productId: 'p1', unitPriceHt: 1000, toStore: '2', toDepot: '3' },
          { productId: 'p2', unitPriceHt: 500, toSplit: '10' },
        ],
      },
      user,
      null,
    );
    expect(calls).toHaveLength(2);
    expect(calls[0]).toMatchObject({
      locationId: 'mag',
      clientMutationId: key,
      lines: [
        { productId: 'p1', receivedQuantity: '2.000', unitPriceHt: 1000 },
      ],
    });
    expect(calls[0].payment).toBeUndefined();
    expect(calls[1]).toMatchObject({
      locationId: 'dep',
      lines: [
        { productId: 'p1', receivedQuantity: '3.000' },
        { productId: 'p2', receivedQuantity: '10.000' },
      ],
      payment: { amount: 5000, fromCash: false },
    });
    expect(calls[1].clientMutationId).not.toBe(key);
    expect(tx.product.updateMany).toHaveBeenCalledWith({
      where: { id: { in: ['p2'] } },
      data: { splitPending: true },
    });
  });

  it('quantité négative : refusée', async () => {
    const { tx, service } = build();
    await expect(
      service.createInTx(
        tx as never,
        {
          clientMutationId: key,
          supplierId: 's1',
          lines: [{ productId: 'p1', unitPriceHt: 1000, toStore: '-1' }],
        },
        user,
        null,
      ),
    ).rejects.toMatchObject({ status: 422 });
  });

  // Audit du 2026-11-19 : un renvoi dont le contenu a changé (panier modifié
  // après une réponse perdue) est un CONFLIT, jamais un faux succès.
  it('renvoi : même contenu reconnu, contenu changé = conflit', async () => {
    const db = {
      location: {
        findFirst: jest.fn(({ where }: { where: { type: string } }) =>
          Promise.resolve({ id: where.type === 'MAGASIN' ? 'mag' : 'dep' }),
        ),
      },
      reception: { count: jest.fn().mockResolvedValue(1) },
    };
    const dto = {
      clientMutationId: key,
      supplierId: 's1',
      lines: [{ productId: 'p1', unitPriceHt: 1000, toStore: '2' }],
    };
    const same = new DirectPurchaseService(
      {} as never,
      {
        replay: jest.fn().mockResolvedValue({ id: 'r1', number: 'REC-1' }),
      } as never,
    );
    await expect(same.replay(db as never, dto, user)).resolves.toMatchObject({
      receptions: [{ number: 'REC-1' }],
    });
    const changed = new DirectPurchaseService(
      {} as never,
      {
        replay: jest.fn().mockResolvedValue(null),
      } as never,
    );
    await expect(changed.replay(db as never, dto, user)).rejects.toMatchObject({
      status: 409,
    });
  });
});
