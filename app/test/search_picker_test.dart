import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gestion_magasin/ui/widgets/search_picker.dart';

typedef _Item = ({String id, String name, String code});

/// Champ de choix avec recherche : remplace les listes déroulantes de 1 000
/// produits (demande MEDMEDBEN du 2026-10-05).
void main() {
  final items = <_Item>[
    for (var i = 0; i < 300; i++)
      (id: 'p$i', name: 'Disjoncteur ${i}A', code: 'DJ-$i'),
    (id: 'cab', name: 'Câble 3G2,5', code: 'CAB-3G25'),
  ];

  Future<List<String?>> pump(WidgetTester tester, {String? value}) async {
    final picked = <String?>[];
    final formKey = GlobalKey<FormState>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Form(
            key: formKey,
            child: Column(
              children: [
                SearchPickerField<_Item>(
                  options: items,
                  idOf: (p) => p.id,
                  labelOf: (p) => '${p.name} · ${p.code}',
                  searchTextOf: (p) => '${p.name} ${p.code}',
                  value: value,
                  hint: 'Produit',
                  onChanged: picked.add,
                  validator: (v) => v == null ? 'Choisissez un produit' : null,
                ),
                TextButton(
                  onPressed: () => formKey.currentState!.validate(),
                  child: const Text('Valider'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    return picked;
  }

  testWidgets('la recherche filtre et le choix remonte', (tester) async {
    final picked = await pump(tester);

    await tester.tap(find.text('Produit'));
    await tester.pumpAndSettle();
    // Liste bornée : on demande de préciser plutôt que d'afficher 301 lignes.
    expect(find.textContaining('précisez la recherche'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'cab 3g');
    await tester.pumpAndSettle();
    expect(find.text('Câble 3G2,5 · CAB-3G25'), findsOneWidget);
    expect(find.textContaining('Disjoncteur'), findsNothing);

    await tester.tap(find.text('Câble 3G2,5 · CAB-3G25'));
    await tester.pumpAndSettle();
    expect(picked, ['cab']);
  });

  testWidgets('rien ne correspond : « Aucun résultat »', (tester) async {
    await pump(tester);
    await tester.tap(find.text('Produit'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'zzz');
    await tester.pumpAndSettle();
    expect(find.text('Aucun résultat'), findsOneWidget);
  });

  testWidgets('annuler ne change rien ; le champ reste obligatoire', (
    tester,
  ) async {
    final picked = await pump(tester);
    await tester.tap(find.text('Produit'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Annuler'));
    await tester.pumpAndSettle();
    expect(picked, isEmpty);

    await tester.tap(find.text('Valider'));
    await tester.pumpAndSettle();
    expect(find.text('Choisissez un produit'), findsOneWidget);
  });

  testWidgets('une valeur posée par le parent s’affiche', (tester) async {
    await pump(tester, value: 'cab');
    expect(find.text('Câble 3G2,5 · CAB-3G25'), findsOneWidget);
  });
}
