import { PrismaService } from '../../prisma/prisma.service';

type Ids = (string | null | undefined)[];

/// Noms lisibles joints à un export : les DTO de liste ne portent que des
/// identifiants. Une requête par table, seulement pour les ids présents.
/// Rien de sensible : nom, référence, unité — ce que chaque rôle lit déjà à
/// l'écran de la liste exportée.
export async function loadExportNames(
  prisma: PrismaService,
  ids: {
    products?: Ids;
    locations?: Ids;
    users?: Ids;
    suppliers?: Ids;
    customers?: Ids;
  },
) {
  const unique = (values: Ids = []) => [
    ...new Set(values.filter((v): v is string => !!v)),
  ];
  const [products, locations, users, suppliers, customers] = await Promise.all([
    ids.products
      ? prisma.product.findMany({
          where: { id: { in: unique(ids.products) } },
          select: { id: true, sku: true, name: true, unit: true },
        })
      : [],
    ids.locations
      ? prisma.location.findMany({
          where: { id: { in: unique(ids.locations) } },
          select: { id: true, name: true },
        })
      : [],
    ids.users
      ? prisma.user.findMany({
          where: { id: { in: unique(ids.users) } },
          select: { id: true, fullName: true },
        })
      : [],
    ids.suppliers
      ? prisma.supplier.findMany({
          where: { id: { in: unique(ids.suppliers) } },
          select: { id: true, name: true },
        })
      : [],
    ids.customers
      ? prisma.customer.findMany({
          where: { id: { in: unique(ids.customers) } },
          select: { id: true, name: true },
        })
      : [],
  ] as const);
  const product = new Map(products.map((p) => [p.id, p]));
  const name = (rows: { id: string; name: string }[]) =>
    new Map(rows.map((r) => [r.id, r.name]));
  const location = name(locations);
  const supplier = name(suppliers);
  const customer = name(customers);
  const user = new Map(users.map((u) => [u.id, u.fullName]));
  const of = (map: Map<string, string>) => (id: string | null | undefined) =>
    id ? (map.get(id) ?? '') : '';
  return {
    sku: (id: string) => product.get(id)?.sku ?? '',
    product: (id: string) => product.get(id)?.name ?? '',
    unit: (id: string) => String(product.get(id)?.unit ?? ''),
    location: of(location),
    user: of(user),
    supplier: of(supplier),
    customer: of(customer),
  };
}
