import 'package:decimal/decimal.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gestion_magasin/core/providers.dart';
import 'package:gestion_magasin/features/catalog/application/catalog_controller.dart';
import 'package:gestion_magasin/features/catalog/data/catalog_models.dart';
import 'package:gestion_magasin/features/payments/data/payment_models.dart';
import 'package:gestion_magasin/features/payments/presentation/payment_history_dialog.dart';
import 'package:gestion_magasin/features/sales/application/sales_controller.dart';
import 'package:gestion_magasin/features/sales/data/sales_api.dart';
import 'package:gestion_magasin/features/sales/data/sales_models.dart';
import 'package:gestion_magasin/features/sales/presentation/sales_screen.dart';
import 'package:gestion_magasin/ui/theme/app_theme.dart';

import 'support/catalog_fakes.dart';
import 'support/fakes.dart';

/// Décisions MEDMEDBEN du 2026-09-16, côté app : échéance des ventes à crédit,
/// contre-passation des paiements (ADMIN), liste des caisses (ADMIN).
class _RecordingSalesApi extends SalesApi {
  _RecordingSalesApi() : super(Dio());

  String? dueDate;

  @override
  Future<Sale> createSale(Map<String, dynamic> body) async {
    final clientMutationId = body['clientMutationId'] as String;
    final paidAmount = body['paidAmount'] as int;
    final dueDate = body['dueDate'] as String?;
    this.dueDate = dueDate;
    return Sale(
      id: clientMutationId,
      number: 'TK-2026-000001',
      type: 'TICKET',
      status: 'VALIDEE',
      totalHt: 100000,
      totalTax: 0,
      totalTtc: 100000,
      paidAmount: paidAmount,
      remainingAmount: 100000 - paidAmount,
      lines: const [],
      soldAt: DateTime.utc(2026, 9, 16),
    );
  }
}

PaymentHistoryItem _payment(
  String id, {
  int amount = 30000,
  String? reverses,
  String? reversedBy,
}) => PaymentHistoryItem(
  id: id,
  amount: amount,
  method: 'ESPECES',
  fromCash: true,
  paidAt: DateTime.utc(2026, 9, 16, 9),
  userId: 'u',
  reversesPaymentId: reverses,
  reversedById: reversedBy,
);

Future<void> _openHistory(
  WidgetTester tester, {
  required List<PaymentHistoryItem> items,
  Future<void> Function(PaymentHistoryItem, String)? onReverse,
}) async {
  useScreenSize(tester, const Size(800, 1000));
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.desktop(dark: true),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showPaymentHistory(
              context,
              title: 'Règlements',
              load: () async => items,
              onReverse: onReverse,
            ),
            child: const Text('ouvrir'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('ouvrir'));
  await tester.pumpAndSettle();
}

void main() {
  test(
    'vente à crédit : l’échéance choisie part au serveur en AAAA-MM-JJ',
    () async {
      final api = _RecordingSalesApi();
      final container = ProviderContainer(
        overrides: [
          salesApiProvider.overrideWithValue(api),
          currentUserIdProvider.overrideWithValue('v'),
          // L'encaissement lit l'estimation du panier (prix appliqués).
          priceTiersProvider.overrideWith(
            (ref) async => const [
              PriceTier(
                id: 'd',
                code: 'DETAIL',
                name: 'Détail',
                isDefault: true,
              ),
            ],
          ),
          taxRatesProvider.overrideWith((ref) => Stream.value(const [])),
        ],
      );
      addTearDown(container.dispose);
      final cart = container.read(cartProvider.notifier);
      cart.add(
        product(id: 'p1').copyWith(
          prices: const [ProductPriceLine(priceTierId: 'd', priceHt: 100000)],
        ),
      );
      expect(container.read(cartProvider).lines.single.quantity, Decimal.one);

      await container
          .read(salesActionsProvider)
          .checkout(
            0,
            expectedTotalTtc: 100000,
            dueDate: DateTime(2026, 10, 5),
          );
      expect(api.dueDate, '2026-10-05');
    },
  );

  testWidgets(
    'historique : « Contre-passer » seulement sur un paiement actif',
    (tester) async {
      await _openHistory(
        tester,
        items: [
          _payment('actif'),
          _payment('annule', reversedBy: 'r1'),
          _payment('r1', amount: -30000, reverses: 'annule'),
        ],
        onReverse: (_, _) async {},
      );
      expect(find.text('Contre-passer'), findsOneWidget);
    },
  );

  testWidgets('contre-passation : motif obligatoire, puis transmis', (
    tester,
  ) async {
    (String, String)? reversed;
    await _openHistory(
      tester,
      items: [_payment('p1')],
      onReverse: (payment, reason) async => reversed = (payment.id, reason),
    );
    await tester.tap(find.text('Contre-passer'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Contre-passer'));
    await tester.pumpAndSettle();
    expect(find.textContaining('motif'), findsOneWidget);
    expect(reversed, isNull);

    await tester.enterText(find.byType(TextField), 'Erreur de saisie');
    await tester.tap(find.widgetWithText(FilledButton, 'Contre-passer'));
    await tester.pumpAndSettle();
    expect(reversed, ('p1', 'Erreur de saisie'));
  });

  testWidgets('sans droit de contre-passer : historique en lecture seule', (
    tester,
  ) async {
    await _openHistory(tester, items: [_payment('p1')]);
    expect(find.text('Contre-passer'), findsNothing);
  });

  test('droits : caisses et contre-passation réservées à l’ADMIN', () {
    final admin = SalesRights(
      authUser(
        roles: const ['ADMIN'],
        permissions: const ['cash.report.read', 'customer.payment.create'],
      ),
    );
    final vendeur = SalesRights(
      authUser(
        roles: const ['VENDEUR'],
        permissions: const ['cash.report.read', 'customer.payment.create'],
      ),
    );
    expect((admin.canSeeAllCash, admin.canReversePayments), (true, true));
    expect((vendeur.canSeeAllCash, vendeur.canReversePayments), (false, false));
  });
}
