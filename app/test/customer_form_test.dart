import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gestion_magasin/core/providers.dart';
import 'package:gestion_magasin/features/catalog/application/catalog_controller.dart';
import 'package:gestion_magasin/features/catalog/data/catalog_models.dart';
import 'package:gestion_magasin/features/sales/data/sales_api.dart';
import 'package:gestion_magasin/features/sales/data/sales_models.dart';
import 'package:gestion_magasin/features/sales/presentation/customer_form.dart';
import 'package:gestion_magasin/ui/theme/app_theme.dart';

import 'support/fakes.dart';

/// Fiche client complète (P1 bis n°21e) : le vendeur crée et modifie la
/// fiche ; tarif et plafond de crédit ne partent QUE de l'administrateur.
class _FakeSalesApi extends SalesApi {
  _FakeSalesApi() : super(Dio());

  final saved = <(String?, Map<String, Object?>)>[];

  @override
  Future<Customer> saveCustomer(String? id, Map<String, Object?> fields) async {
    saved.add((id, fields));
    return Customer(
      id: id ?? 'c-new',
      name: fields['name']! as String,
      creditLimit: 0,
      balanceDue: 0,
      isActive: true,
    );
  }
}

Future<_FakeSalesApi> _pump(
  WidgetTester tester, {
  required bool admin,
  Customer? existing,
}) async {
  useScreenSize(tester, const Size(700, 1400));
  final api = _FakeSalesApi();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        salesApiProvider.overrideWithValue(api),
        currentUserIdProvider.overrideWithValue('u'),
        priceTiersProvider.overrideWith(
          (ref) async => const [
            PriceTier(
              id: 'detail',
              code: 'DETAIL',
              name: 'Détail',
              isDefault: true,
            ),
            PriceTier(id: 'gros', code: 'GROS', name: 'Gros', isDefault: false),
          ],
        ),
      ],
      child: MaterialApp(
        theme: AppTheme.desktop(dark: true),
        home: Scaffold(
          body: CustomerForm(existing: existing, canManageTerms: admin),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return api;
}

void main() {
  testWidgets('vendeur : fiche complète, SANS tarif ni plafond envoyés', (
    tester,
  ) async {
    final api = await _pump(tester, admin: false);
    expect(find.text('Plafond de crédit'), findsNothing);
    expect(find.text('Tarif'), findsNothing);

    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), 'Électricité Benali');
    await tester.enterText(fields.at(2), 'benali@exemple.dz');
    await tester.enterText(fields.at(3), 'Cité 20 août, Oran');
    await tester.tap(find.text('Enregistrer'));
    await tester.pumpAndSettle();

    final (id, sent) = api.saved.single;
    expect(id, isNull);
    expect(sent['email'], 'benali@exemple.dz');
    expect(sent['address'], 'Cité 20 août, Oran');
    expect(sent.containsKey('creditLimit'), isFalse);
    expect(sent.containsKey('priceTierId'), isFalse);
  });

  testWidgets('admin : tarif et plafond de crédit modifiables', (tester) async {
    final api = await _pump(
      tester,
      admin: true,
      existing: const Customer(
        id: 'c1',
        name: 'Benali',
        creditLimit: 0,
        balanceDue: 0,
        isActive: true,
      ),
    );
    await tester.enterText(find.byType(TextFormField).last, '50000');
    await tester.tap(find.text('Tarif par défaut'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Gros').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Enregistrer'));
    await tester.pumpAndSettle();

    final (id, sent) = api.saved.single;
    expect(id, 'c1');
    expect(sent['creditLimit'], 5000000);
    expect(sent['priceTierId'], 'gros');
  });
}
