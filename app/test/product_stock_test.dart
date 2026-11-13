import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gestion_magasin/features/stock/application/stock_controller.dart';
import 'package:gestion_magasin/features/stock/data/stock_models.dart';

StockLevel _level(String location, String? type, String qty) => StockLevel(
  productId: 'p1',
  locationId: location,
  locationType: type,
  quantity: Decimal.parse(qty),
  reservedQuantity: Decimal.zero,
  inTransitQuantity: Decimal.zero,
  availableQuantity: Decimal.parse(qty),
);

void main() {
  // 2026-11-13 : « Rupture » partout en Vente — le magasin était cherché par
  // un id périmé du cache. Le stock se lit maintenant par TYPE de lieu.
  test('stock par type de lieu, quel que soit l’id du cache', () {
    final stock = ProductStock([
      _level('magasin-serveur', 'MAGASIN', '20'),
      _level('depot-serveur', 'DEPOT', '5'),
    ]);
    expect(stock.ofType('MAGASIN', {'ancien-id'}), Decimal.fromInt(20));
    expect(stock.ofType('DEPOT'), Decimal.fromInt(5));
    expect(stock.ofType('TRANSIT'), Decimal.zero);
  });

  test('serveur sans le type : repli sur les ids du cache', () {
    final stock = ProductStock([_level('m1', null, '7')]);
    expect(stock.ofType('MAGASIN', {'m1'}), Decimal.fromInt(7));
    expect(stock.ofType('MAGASIN', {'autre'}), Decimal.zero);
  });
}
