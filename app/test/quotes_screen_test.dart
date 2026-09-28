import 'dart:typed_data';

import 'package:decimal/decimal.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:gestion_magasin/core/error/api_exception.dart';
import 'package:gestion_magasin/core/money.dart';
import 'package:gestion_magasin/core/providers.dart';
import 'package:gestion_magasin/data/models/page_meta.dart';
import 'package:gestion_magasin/features/auth/data/auth_models.dart';
import 'package:gestion_magasin/features/catalog/data/catalog_api.dart';
import 'package:gestion_magasin/features/catalog/data/catalog_models.dart';
import 'package:gestion_magasin/features/catalog/data/catalog_repository.dart';
import 'package:gestion_magasin/features/quotes/application/quotes_controller.dart';
import 'package:gestion_magasin/features/quotes/data/quote_models.dart';
import 'package:gestion_magasin/features/quotes/data/quotes_api.dart';
import 'package:gestion_magasin/features/quotes/presentation/quotes_screen.dart';
import 'package:gestion_magasin/features/sales/application/sales_controller.dart';
import 'package:gestion_magasin/features/sales/data/sales_models.dart';
import 'package:gestion_magasin/ui/navigation.dart';
import 'package:gestion_magasin/ui/theme/app_theme.dart';

import 'support/catalog_fakes.dart';
import 'support/fakes.dart';

/// Devis (P1 n°21a). Le serveur fixe prix, statuts et conversion ; l'écran
/// propose exactement les actions que le serveur accepte.
Quote _quote(String id, QuoteStatus status, {String? customer}) => Quote(
  id: id,
  number: 'DV-2026-0000$id',
  status: status,
  customerId: customer == null ? null : 'c-$id',
  customerName: customer,
  userId: 'v',
  validUntil: '2026-10-26',
  totalHt: 100000,
  totalTax: 19000,
  totalTtc: 119000,
  createdAt: DateTime.utc(2026, 9, 26),
);

class _FakeQuotesApi extends QuotesApi {
  _FakeQuotesApi(this.quotes) : super(Dio());

  final List<Quote> quotes;
  final created = <Map<String, Object?>>[];
  final converted = <Map<String, Object?>>[];
  ApiException? failNext;

  @override
  Future<QuotePage> list({QuoteStatus? status, int limit = 100}) async =>
      QuotePage(
        data: [
          for (final q in quotes)
            if (status == null || q.status == status) q,
        ],
        meta: PageMeta(page: 1, limit: limit, total: quotes.length),
      );

  @override
  Future<Quote> create({
    required String id,
    String? customerId,
    String? validUntil,
    required List<
      ({
        String productId,
        String quantity,
        int? unitPriceHt,
        int discountAmount,
      })
    >
    lines,
  }) async {
    created.add({'id': id, 'lines': lines, 'validUntil': validUntil});
    if (failNext case final error?) {
      failNext = null;
      throw error;
    }
    return _quote('9', QuoteStatus.draft);
  }

  @override
  Future<Sale> convert(
    String id, {
    required String clientMutationId,
    required int paidAmount,
    required int expectedTotalTtc,
    String? cashSessionId,
    String? dueDate,
  }) async {
    converted.add({
      'id': id,
      'key': clientMutationId,
      'paidAmount': paidAmount,
      'cash': cashSessionId,
    });
    if (failNext case final error?) {
      failNext = null;
      throw error;
    }
    return Sale(
      id: 's1',
      number: 'TK-2026-000042',
      type: 'TICKET',
      status: 'VALIDEE',
      totalHt: 100000,
      totalTax: 19000,
      totalTtc: 119000,
      paidAmount: paidAmount,
      remainingAmount: 119000 - paidAmount,
      lines: const [],
      soldAt: DateTime.utc(2026, 9, 26),
    );
  }

  @override
  Future<Uint8List> document(String id) async => Uint8List(4);

  final updated = <(String, String?, List<QuoteLineInput>)>[];

  @override
  Future<Quote> update(
    String id, {
    String? customerId,
    required List<QuoteLineInput> lines,
  }) async {
    updated.add((id, customerId, lines));
    return _quote('1', QuoteStatus.draft);
  }
}

/// Catalogue local réduit à une liste de produits.
class _Catalog implements CatalogRepository {
  _Catalog(this.products);

  final List<Product> products;

  @override
  Stream<List<Product>> watchProducts({
    String search = '',
    Set<String>? categoryIds,
    bool includeInactive = false,
  }) => Stream.value(products);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Tiers extends RecordingCatalogApi {
  @override
  Future<List<PriceTier>> priceTiers() async => const [
    PriceTier(id: 'd', code: 'DETAIL', name: 'Détail', isDefault: true),
  ];
}

final _openCash = CashSession(
  id: 'cash',
  status: 'OUVERTE',
  openingFloat: 0,
  cashSalesAmount: 0,
  cashSalesCount: 0,
  currentAmount: 0,
  openedAt: DateTime.utc(2026, 9, 26, 8),
);

List<Override> _overrides(_FakeQuotesApi api, {CashSession? cash}) => [
  quotesApiProvider.overrideWithValue(api),
  currentUserIdProvider.overrideWithValue('v'),
  currentCashSessionProvider.overrideWith((ref) async => cash),
];

Future<_FakeQuotesApi> _pump(
  WidgetTester tester,
  List<Quote> quotes, {
  CashSession? cash,
  String userId = 'v',
}) async {
  useScreenSize(tester, const Size(900, 1200));
  final api = _FakeQuotesApi(quotes);
  await tester.pumpWidget(
    ProviderScope(
      overrides: _overrides(api, cash: cash),
      child: MaterialApp(
        theme: AppTheme.mobile(dark: true),
        home: Scaffold(
          body: QuotesScreen(
            user: authUser(
              id: userId,
              roles: const ['VENDEUR'],
              permissions: const ['sale.create'],
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return api;
}

void main() {
  testWidgets('liste : numéro, client, total et statut', (tester) async {
    await _pump(tester, [
      _quote('1', QuoteStatus.draft, customer: 'Électricité Benali'),
      _quote('2', QuoteStatus.expired),
    ]);

    expect(
      find.textContaining('DV-2026-00001 · Électricité Benali'),
      findsOneWidget,
    );
    expect(find.textContaining('Client comptoir'), findsOneWidget);
    expect(find.textContaining(formatDA(119000)), findsNWidgets(2));
    expect(find.text('Expiré'), findsWidgets);
  });

  /// L'écran ne propose que ce que le serveur accepte : un brouillon ne se
  /// convertit pas, un devis expiré ne s'accepte plus.
  testWidgets('actions selon le statut, miroir du serveur', (tester) async {
    await _pump(tester, [
      _quote('1', QuoteStatus.draft),
      _quote('2', QuoteStatus.accepted),
      _quote('3', QuoteStatus.expired),
    ]);

    await tester.tap(find.textContaining('DV-2026-00001'));
    await tester.pumpAndSettle();
    expect(find.text('Marquer comme envoyé au client'), findsOneWidget);
    expect(find.text('Le client accepte'), findsOneWidget);
    expect(find.textContaining('Convertir en vente'), findsNothing);
    await tester.tapAt(Offset.zero);
    await tester.pumpAndSettle();

    await tester.tap(find.textContaining('DV-2026-00002'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Convertir en vente'), findsOneWidget);
    expect(find.text('Le client accepte'), findsNothing);
    await tester.tapAt(Offset.zero);
    await tester.pumpAndSettle();

    await tester.tap(find.textContaining('DV-2026-00003'));
    await tester.pumpAndSettle();
    expect(find.text('Imprimer / partager le PDF'), findsOneWidget);
    expect(find.text('Le client accepte'), findsNothing);
    expect(find.text('Marquer comme envoyé au client'), findsNothing);
    expect(find.textContaining('Convertir en vente'), findsNothing);
    expect(find.text('Le client refuse'), findsOneWidget);
  });

  /// Coupure pendant la conversion : on ne sait pas si la vente est faite. Le
  /// nouvel essai porte la MÊME clé, le serveur rend la vente déjà faite.
  test('conversion : la clé survit à une coupure', () async {
    final api = _FakeQuotesApi([]);
    final container = ProviderContainer(
      overrides: _overrides(api, cash: _openCash),
    );
    addTearDown(container.dispose);
    final quote = _quote('2', QuoteStatus.accepted);
    final actions = container.read(quoteActionsProvider);

    api.failNext = const ApiException(statusCode: 0, message: 'coupure');
    await expectLater(
      actions.convert(quote, paidAmount: 119000),
      throwsA(isA<ApiException>()),
    );
    await actions.convert(quote, paidAmount: 119000);

    expect(api.converted, hasLength(2));
    expect(api.converted[1]['key'], api.converted[0]['key']);
  });

  testWidgets('conversion : encaissement dans la caisse ouverte', (
    tester,
  ) async {
    final api = await _pump(tester, [
      _quote('2', QuoteStatus.accepted),
    ], cash: _openCash);

    await tester.tap(find.textContaining('DV-2026-00002'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Convertir en vente'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Valider la vente'));
    await tester.pumpAndSettle();

    expect(api.converted.single, {
      'id': '2',
      'key': api.converted.single['key'],
      'paidAmount': 119000,
      'cash': 'cash',
    });
    expect(find.text('Vente TK-2026-000042 enregistrée.'), findsOneWidget);
  });

  testWidgets('conversion en espèces sans caisse ouverte : refusée à l’écran', (
    tester,
  ) async {
    final api = await _pump(tester, [_quote('2', QuoteStatus.accepted)]);

    await tester.tap(find.textContaining('DV-2026-00002'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Convertir en vente'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Valider la vente'));
    await tester.pumpAndSettle();

    expect(api.converted, isEmpty);
    expect(
      find.text('Ouvrez une session de caisse au préalable'),
      findsOneWidget,
    );
  });

  /// « Faire un devis » : le panier de la Vente devient un devis, puis se vide.
  /// Un essai perdu sur le réseau repart avec le MÊME id : jamais deux devis.
  test(
    'devis du panier : même id au nouvel essai, panier vidé au succès',
    () async {
      final api = _FakeQuotesApi([]);
      final container = ProviderContainer(overrides: _overrides(api));
      addTearDown(container.dispose);
      final cart = container.read(cartProvider.notifier);
      cart.add(product(id: 'p1', name: 'Câble'), Decimal.parse('2.5'));
      cart.setPrice('p1', 150000);
      cart.setDiscount('p1', 2500);

      api.failNext = const ApiException(statusCode: 0, message: 'coupure');
      final actions = container.read(quoteActionsProvider);
      await expectLater(actions.createFromCart(), throwsA(isA<ApiException>()));
      expect(container.read(cartProvider).isEmpty, isFalse);

      await actions.createFromCart();
      expect(api.created, hasLength(2));
      expect(api.created[1]['id'], api.created[0]['id']);
      final lines =
          api.created[1]['lines']!
              as List<
                ({
                  String productId,
                  String quantity,
                  int? unitPriceHt,
                  int discountAmount,
                })
              >;
      expect(lines.single.productId, 'p1');
      expect(lines.single.quantity, '2.500');
      expect(lines.single.unitPriceHt, 150000);
      // La remise du panier part avec le devis (P1 bis n°21g).
      expect(lines.single.discountAmount, 2500);
      expect(container.read(cartProvider).isEmpty, isTrue);
    },
  );

  /// P1 bis n°21m : un brouillon revient dans le panier de la Vente ; un prix
  /// égal au tarif redevient « au tarif », un prix modifié le reste ; la mise
  /// à jour remplace ses lignes et vide le panier.
  test('modifier un brouillon : panier chargé, puis mise à jour', () async {
    final api = _FakeQuotesApi([]);
    ProductPriceLine detail(int price) =>
        ProductPriceLine(priceTierId: 'd', priceHt: price);
    final container = ProviderContainer(
      overrides: [
        ..._overrides(api),
        catalogRepositoryProvider.overrideWithValue(
          _Catalog([
            product(id: 'p1').copyWith(prices: [detail(145000)]),
            product(id: 'p2', name: 'Câble').copyWith(prices: [detail(145000)]),
          ]),
        ),
        catalogApiProvider.overrideWithValue(_Tiers()),
      ],
    );
    addTearDown(container.dispose);
    QuoteLine line(String productId, int price) => QuoteLine(
      id: 'l-$productId',
      productId: productId,
      quantity: '2.500',
      unitPriceHt: price,
      taxRate: '19.00',
      lineTotalHt: 0,
      lineTaxAmount: 0,
      lineTotalTtc: 0,
    );
    final draft = _quote(
      '1',
      QuoteStatus.draft,
    ).copyWith(lines: [line('p1', 145000), line('p2', 130000)]);

    await container.read(quoteActionsProvider).editInCart(draft);
    final cart = container.read(cartProvider);
    expect(cart.quote?.id, '1');
    expect(cart.lines.map((l) => l.unitPriceHt), [null, 130000]);
    expect(cart.lines.first.quantity, Decimal.parse('2.5'));

    container.read(cartProvider.notifier).setQuantity('p1', Decimal.one);
    await container.read(quoteActionsProvider).updateFromCart();
    final (id, customerId, lines) = api.updated.single;
    expect(id, '1');
    expect(customerId, isNull);
    expect(lines.map((l) => (l.productId, l.quantity, l.unitPriceHt)), [
      ('p1', '1.000', null),
      ('p2', '2.500', 130000),
    ]);
    expect(container.read(cartProvider).quote, isNull);
    expect(container.read(cartProvider).isEmpty, isTrue);
  });

  testWidgets('seul un brouillon propose « Modifier »', (tester) async {
    await _pump(tester, [
      _quote('1', QuoteStatus.draft),
      _quote('2', QuoteStatus.sent),
    ]);
    await tester.tap(find.textContaining('DV-2026-00001'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Modifier'), findsOneWidget);
    await tester.tapAt(Offset.zero);
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('DV-2026-00002'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Modifier'), findsNothing);
  });

  testWidgets('le brouillon d’un collègue : pas de « Modifier »', (
    tester,
  ) async {
    await _pump(tester, [_quote('1', QuoteStatus.draft)], userId: 'autre');
    await tester.tap(find.textContaining('DV-2026-00001'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Modifier'), findsNothing);
  });

  test('menu « Devis » : ADMIN et VENDEUR, jamais le magasinier', () {
    bool offered(AuthUser user) =>
        destinationsFor(user).any((d) => d.label == 'Devis');
    expect(
      offered(
        authUser(roles: const ['VENDEUR'], permissions: const ['sale.create']),
      ),
      isTrue,
    );
    expect(
      offered(
        authUser(roles: const ['ADMIN'], permissions: const ['sale.create']),
      ),
      isTrue,
    );
    expect(
      offered(
        authUser(
          roles: const ['MAGASINIER'],
          permissions: const ['product.read'],
        ),
      ),
      isFalse,
    );
    expect(
      offered(authUser(roles: const ['VENDEUR'], permissions: const [])),
      isFalse,
    );
  });
}
