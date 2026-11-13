import { CatalogService } from './catalog.service';

// Un curseur émis par une AUTRE base (nouveau serveur) => `reset` et tout
// le catalogue redescend ; le même curseur sur la même base => delta normal.
describe('CatalogService.changes — identité de la base', () => {
  const empty = { findMany: jest.fn().mockResolvedValue([]) };
  const prisma = {
    product: empty,
    category: empty,
    taxRate: empty,
    location: {
      findMany: jest.fn().mockResolvedValue([]),
      findFirst: jest.fn().mockResolvedValue({ id: 'base-A' }),
    },
  };
  const service = new CatalogService(prisma as never);
  const viewer = { permissions: [] };
  const encode = (c: object) =>
    Buffer.from(JSON.stringify(c)).toString('base64url');

  it('premier appel : pas de reset, le curseur porte la base', async () => {
    const page = await service.changes({ limit: 10 } as never, viewer);
    expect(page.reset).toBe(false);
    const cursor = JSON.parse(Buffer.from(page.cursor, 'base64url').toString());
    expect(cursor.ds).toBe('base-A');
  });

  it('même base : pas de reset', async () => {
    const page = await service.changes(
      { limit: 10, cursor: encode({ ds: 'base-A' }) } as never,
      viewer,
    );
    expect(page.reset).toBe(false);
  });

  it('autre base ou curseur ancien : reset', async () => {
    for (const old of [{ ds: 'base-B' }, {}]) {
      const page = await service.changes(
        { limit: 10, cursor: encode(old) } as never,
        viewer,
      );
      expect(page.reset).toBe(true);
    }
  });
});
