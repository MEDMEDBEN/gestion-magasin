import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gestion_magasin/core/money.dart';
import 'package:gestion_magasin/data/models/page_meta.dart';
import 'package:gestion_magasin/features/auth/data/auth_models.dart';
import 'package:gestion_magasin/features/suppliers/data/suppliers_api.dart';
import 'package:gestion_magasin/features/suppliers/data/suppliers_models.dart';
import 'package:gestion_magasin/features/suppliers/presentation/suppliers_screen.dart';
import 'package:gestion_magasin/ui/navigation.dart';
import 'package:gestion_magasin/ui/theme/app_theme.dart';

import 'support/fakes.dart';

class _FakeSuppliersApi extends SuppliersApi {
  _FakeSuppliersApi() : super(Dio());

  Map<String, Object?>? payment;
  Map<String, Object?>? saved;

  final _suppliers = [
    const Supplier(
      id: 's1',
      name: 'Sonelec',
      phone: '0550 11 22 33',
      contactName: 'M. Rahmani',
      openingBalance: 500000,
      paidAmount: 200000,
      balanceDue: 300000,
      isActive: true,
    ),
    const Supplier(
      id: 's2',
      name: 'Câbles du Sud',
      openingBalance: 0,
      paidAmount: 0,
      balanceDue: 0,
      isActive: true,
    ),
  ];

  @override
  Future<SupplierPage> list({
    String? query,
    bool includeInactive = false,
  }) async {
    final match = query == null
        ? _suppliers
        : _suppliers
              .where((s) => s.name.toLowerCase().contains(query.toLowerCase()))
              .toList();
    return SupplierPage(
      data: match,
      meta: PageMeta(page: 1, limit: 200, total: match.length),
    );
  }

  @override
  Future<SupplierPayment> pay(Map<String, Object?> fields) async {
    payment = fields;
    final amount = fields['amount']! as int;
    return SupplierPayment(
      id: fields['id']! as String,
      supplierId: fields['supplierId']! as String,
      amount: amount,
      method: fields['fromCash'] == true ? 'ESPECES' : 'VIREMENT',
      fromCash: fields['fromCash']! as bool,
      paidAt: DateTime.utc(2026, 9, 16),
      balanceDue: 300000 - amount,
    );
  }

  @override
  Future<Supplier> create(Map<String, Object?> fields) async {
    saved = fields;
    return _suppliers.first;
  }
}

AuthUser _admin() => authUser(
  id: 'a',
  roles: const ['ADMIN'],
  permissions: const [
    'supplier.read',
    'supplier.write',
    'supplier.payment.create',
  ],
);

Future<_FakeSuppliersApi> _pump(WidgetTester tester, AuthUser user) async {
  useScreenSize(tester, const Size(500, 1000));
  final api = _FakeSuppliersApi();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [suppliersApiProvider.overrideWithValue(api)],
      child: MaterialApp(
        theme: AppTheme.mobile(dark: true),
        home: Scaffold(body: SuppliersScreen(user: user)),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return api;
}

void main() {
  testWidgets('liste : dette affichée, « à jour » sans dette', (tester) async {
    await _pump(tester, _admin());

    expect(find.text('Sonelec'), findsOneWidget);
    expect(find.text('Dette ${formatDA(300000)}'), findsOneWidget);
    expect(find.text('À jour'), findsOneWidget);
  });

  testWidgets('paiement hors caisse : montant et choix envoyés au serveur', (
    tester,
  ) async {
    final api = await _pump(tester, _admin());

    await tester.tap(find.text('Sonelec'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Enregistrer un paiement'));
    await tester.pumpAndSettle();

    // Le dialogue propose le reste dû ; le paiement part hors caisse.
    expect(
      find.widgetWithText(TextField, formatDA(300000, withSymbol: false)),
      findsOneWidget,
    );
    await tester.enterText(find.byType(TextField).last, '1000');
    await tester.tap(find.text('Payé depuis la caisse'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Enregistrer'));
    await tester.pumpAndSettle();

    expect(api.payment, containsPair('amount', 100000));
    expect(api.payment, containsPair('fromCash', false));
    expect(api.payment, containsPair('supplierId', 's1'));
    expect(find.textContaining('reste dû'), findsOneWidget);
  });

  testWidgets('paiement refusé au-delà du reste dû (avant tout appel)', (
    tester,
  ) async {
    final api = await _pump(tester, _admin());

    await tester.tap(find.text('Sonelec'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Enregistrer un paiement'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '9999');
    await tester.tap(find.text('Enregistrer'));
    await tester.pumpAndSettle();

    expect(find.text('Au-delà du reste dû'), findsOneWidget);
    expect(api.payment, isNull);
  });

  testWidgets('MAGASINIER : lecture seule, ni création ni paiement', (
    tester,
  ) async {
    await _pump(
      tester,
      authUser(
        id: 'm',
        roles: const ['MAGASINIER'],
        permissions: const ['supplier.read'],
      ),
    );

    expect(find.text('Nouveau'), findsNothing);
    await tester.tap(find.text('Sonelec'));
    await tester.pumpAndSettle();
    expect(find.text('Enregistrer un paiement'), findsNothing);
    expect(find.text('Modifier la fiche'), findsNothing);
  });

  test('menu : « Fournisseurs » pour ADMIN/MAGASINIER, jamais le vendeur', () {
    expect(
      destinationsFor(_admin()).map((d) => d.label),
      contains('Fournisseurs'),
    );
    expect(
      destinationsFor(
        authUser(
          roles: const ['VENDEUR'],
          // Même avec la permission posée en base, le rôle ferme la porte.
          permissions: const ['supplier.read'],
        ),
      ).map((d) => d.label),
      isNot(contains('Fournisseurs')),
    );
  });
}
