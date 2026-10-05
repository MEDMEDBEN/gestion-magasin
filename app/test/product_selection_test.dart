import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gestion_magasin/features/catalog/application/catalog_controller.dart';

import 'support/catalog_fakes.dart';

/// Sélection du catalogue (audit du 2026-10-06) : elle garde les PRODUITS
/// cochés et traverse les recherches ; « Tout sélectionner » AJOUTE.
void main() {
  late ProviderContainer container;
  setUp(() {
    container = ProviderContainer();
    addTearDown(container.dispose);
    container.listen(productSelectionProvider, (_, _) {});
  });

  ProductSelection selection() =>
      container.read(productSelectionProvider.notifier);
  Set<String>? ids() => container.read(productSelectionProvider)?.keys.toSet();

  test('hors mode : rien ; en mode : cocher, décocher', () {
    expect(ids(), isNull);
    selection().start();
    selection().toggle(product(id: 'a', name: 'Câble'));
    selection().toggle(product(id: 'b', name: 'Gaine'));
    expect(ids(), {'a', 'b'});
    selection().toggle(product(id: 'a', name: 'Câble'));
    expect(ids(), {'b'});
  });

  test('un produit coché puis masqué (autre recherche) reste choisi', () {
    selection().start();
    selection().toggle(product(id: 'a', name: 'Câble'));
    // Nouvelle recherche : seuls « Disjoncteur » et « Gaine » sont affichés,
    // « Tout sélectionner » les AJOUTE sans perdre « Câble ».
    selection().addAll([
      product(id: 'd', name: 'Disjoncteur'),
      product(id: 'g', name: 'Gaine'),
    ]);
    expect(ids(), {'a', 'd', 'g'});
    expect(
      container.read(productSelectionProvider)!.values.map((p) => p.name),
      containsAll(['Câble', 'Disjoncteur', 'Gaine']),
    );
    selection().stop();
    expect(ids(), isNull);
  });
}
