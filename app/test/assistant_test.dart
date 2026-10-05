import 'package:flutter_test/flutter_test.dart';
import 'package:gestion_magasin/features/assistant/assistant.dart';

import 'support/fakes.dart';

/// Assistant (2026-10-05) : actions préparées, reconnues par mots-clés en
/// français, darija et anglais. Pas d'IA : une liste, et ces règles.
void main() {
  final admin = authUser(
    roles: const ['ADMIN'],
    permissions: const [
      'product.read',
      'product.write',
      'price.read',
      'sale.create',
      'stock.read.store',
      'transfer.request',
      'purchase.create',
      'supplier.read',
      'audit.read',
    ],
  );
  final commands = commandsFor(admin);
  AssistantMatch first(String input) => matchCommands(input, commands).first;

  test('« ajouter » en trois langues, le nom en argument', () {
    for (final phrase in [
      'ajoute câble 3G2,5',
      'zid câble 3G2,5',
      'add câble 3G2,5',
      'Ajouter un nouveau produit câble 3G2,5',
    ]) {
      final m = first(phrase);
      expect(m.command.title, 'Ajouter un produit', reason: phrase);
      expect(m.argument, 'câble 3G2,5', reason: phrase);
    }
  });

  test('vendre, chercher, stock, étiquette, aide', () {
    expect(first('bi3').command.title, 'Nouvelle vente');
    expect(first('sell').command.title, 'Nouvelle vente');
    expect(first('chof disjoncteur').command.title, 'Chercher un produit');
    expect(first('chof disjoncteur').argument, 'disjoncteur');
    expect(first('stock gaine').command.title, 'Voir le stock');
    // Accents et majuscules ignorés, début de mot reconnu.
    expect(first('ÉTIQ gaine').command.title, 'Étiquettes d’un produit');
    expect(first('kifach').command.title, 'Guide d’utilisation');
  });

  test('rien tapé : toutes les actions ; rien reconnu : aucune', () {
    expect(matchCommands('', commands), hasLength(commands.length));
    expect(matchCommands('xyzzy', commands), isEmpty);
  });

  test('une action n’est proposée que si le compte a son écran', () {
    final vendeur = authUser(
      roles: const ['VENDEUR'],
      permissions: const ['product.read', 'price.read', 'sale.create'],
    );
    final titles = commandsFor(vendeur).map((c) => c.title).toList();
    expect(titles, contains('Nouvelle vente'));
    // Le vendeur ne crée pas de produit, n'a ni achats ni historique.
    expect(titles, isNot(contains('Ajouter un produit')));
    expect(titles, isNot(contains('Commande fournisseur')));
    expect(titles, isNot(contains('Historique')));
    expect(titles, contains('Guide d’utilisation'));
  });
}
