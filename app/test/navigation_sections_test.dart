import 'package:flutter_test/flutter_test.dart';
import 'package:gestion_magasin/ui/navigation.dart';

import 'support/fakes.dart';

/// Rubriques regroupées en sections (2026-10-28) : moins d'entrées, AUCUNE
/// rubrique perdue, droits inchangés.
void main() {
  test('admin : sections formées, aucune rubrique perdue', () {
    final user = authUser(
      permissions: const [
        'audit.read',
        'inventory.create',
        'product.read',
        'purchase.create',
        'sale.create',
        'stock.read.store',
        'supplier.read',
        'user.manage',
      ],
    );
    final flat = destinationsFor(user).map((d) => d.label).toSet();
    final menu = menuFor(user);

    expect(menu.length, lessThan(flat.length));
    final reached = {
      for (final d in menu)
        if (d.sections.isEmpty) d.label else ...d.sections.map((s) => s.label),
    };
    expect(reached, flat);

    final achats = menu.firstWhere((d) => d.label == 'Achats');
    expect(achats.sections.map((s) => s.label), [
      'Achats',
      'Réappro',
      'Fournisseurs',
    ]);
    expect(locate(menu, 'Réappro'), (index: menu.indexOf(achats), section: 1));
    final users = menu.indexWhere((d) => d.label == 'Utilisateurs');
    expect(locate(menu, 'Historique'), (index: users, section: 1));
  });

  test('vendeur : pas de section vide, ses rubriques seulement', () {
    final user = authUser(
      roles: const ['VENDEUR'],
      permissions: const ['sale.create', 'product.read'],
    );
    final menu = menuFor(user);
    // Achats et Fournisseurs lui sont fermés : pas de section Achats.
    expect(menu.any((d) => d.label == 'Achats'), isFalse);
    expect(locate(menu, 'Fournisseurs'), isNull);
    // Vente regroupe Vente et Devis.
    final vente = menu.firstWhere((d) => d.label == 'Vente');
    expect(vente.sections.map((s) => s.label), ['Vente', 'Devis']);
  });
}
