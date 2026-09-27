import { PERMISSIONS } from '../common/permissions';
import { ProductsService } from './products.service';

/// Le prix d'achat initial fixe la marge et le plancher du prix de vente :
/// `price.manage`, comme les tarifs. Aucun rôle par défaut n'a `product.write`
/// sans `price.manage` : la garde n'est prouvable qu'ici.
describe('prix d’achat initial : droit price.manage', () => {
  const user = (permissions: string[]) =>
    ({ permissions }) as unknown as Parameters<
      typeof ProductsService.assertCanSetCost
    >[1];

  it('refusé sans price.manage, accepté avec ; sans prix, rien à contrôler', () => {
    expect(() =>
      ProductsService.assertCanSetCost(
        { purchasePriceHt: 100 },
        user([PERMISSIONS.PRODUCT_WRITE]),
      ),
    ).toThrow('price.manage');
    expect(() =>
      ProductsService.assertCanSetCost(
        { purchasePriceHt: 100 },
        user([PERMISSIONS.PRODUCT_WRITE, PERMISSIONS.PRICE_MANAGE]),
      ),
    ).not.toThrow();
    expect(() =>
      ProductsService.assertCanSetCost({}, user([PERMISSIONS.PRODUCT_WRITE])),
    ).not.toThrow();
  });
});
