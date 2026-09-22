import 'dart:convert';
import 'dart:typed_data';

import 'package:decimal/decimal.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gestion_magasin/core/error/api_exception.dart';
import 'package:gestion_magasin/core/providers.dart';
import 'package:gestion_magasin/data/local/app_database.dart';
import 'package:gestion_magasin/data/local/mutation_queue.dart';
import 'package:gestion_magasin/features/auth/data/auth_models.dart';
import 'package:gestion_magasin/features/catalog/application/catalog_controller.dart';
import 'package:gestion_magasin/features/catalog/data/catalog_models.dart';
import 'package:gestion_magasin/features/sales/application/sales_controller.dart';
import 'package:gestion_magasin/features/sales/data/sales_api.dart';
import 'package:gestion_magasin/features/sales/data/sales_models.dart';
import 'package:gestion_magasin/features/sales/presentation/sales_screen.dart';
import 'package:gestion_magasin/ui/navigation.dart';
import 'package:gestion_magasin/ui/theme/app_theme.dart';

import 'support/catalog_fakes.dart';
import 'support/fakes.dart';

StorageLocation _store() => StorageLocation(
  id: 'magasin',
  code: 'MAG',
  name: 'Magasin',
  type: 'MAGASIN',
  isActive: true,
  updatedAt: DateTime.utc(2026),
);

class _FakeSalesApi extends SalesApi {
  _FakeSalesApi({this.cash, this.failure, this.offline = false}) : super(Dio());

  final CashSession? cash;
  final ApiException? failure;

  /// Aucune réponse du serveur, sur TOUTES les routes.
  final bool offline;
  static const _noNetwork = ApiException(statusCode: 0, message: 'hors ligne');
  final cashCalls = <String>[];

  @override
  Future<CashSession> openCashSession(Map<String, dynamic> body) async {
    cashCalls.add('open');
    throw _noNetwork;
  }

  @override
  Future<CashSession> closeCashSession(
    String id,
    Map<String, dynamic> body,
  ) async {
    cashCalls.add('close');
    throw _noNetwork;
  }

  Map<String, Object?>? sent;

  @override
  Future<CashSession?> currentCashSession() async {
    if (offline) throw _noNetwork;
    return cash;
  }

  @override
  Future<Uint8List> saleDocument(String saleId) async =>
      Uint8List.fromList('%PDF-1.3'.codeUnits);

  @override
  Future<Sale> createSale(Map<String, dynamic> body) async {
    final clientMutationId = body['clientMutationId'] as String;
    final paidAmount = body['paidAmount'] as int;
    sent = body;
    if (failure != null) throw failure!;
    return Sale(
      id: clientMutationId,
      number: 'TK-2026-000042',
      type: 'TICKET',
      status: 'VALIDEE',
      totalHt: 362500,
      totalTax: 68875,
      totalTtc: 431375,
      paidAmount: paidAmount,
      remainingAmount: 0,
      lines: const [],
      soldAt: DateTime.utc(2026, 9, 15),
    );
  }
}

final _openCash = CashSession(
  id: 'cash',
  status: 'OUVERTE',
  openingFloat: 500000,
  cashSalesAmount: 0,
  cashSalesCount: 0,
  currentAmount: 500000,
  openedAt: DateTime.utc(2026, 9, 15, 8),
);

Product _cable() =>
    product(id: 'p1', name: 'Câble 3G2,5', barcode: '3245060123458').copyWith(
      taxRateId: 'tva19',
      prices: const [ProductPriceLine(priceTierId: 'detail', priceHt: 145000)],
    );

AuthUser _vendeur() => authUser(
  id: 'v',
  roles: const ['VENDEUR'],
  permissions: const [
    'sale.create',
    'invoice.issue',
    'cash.session.manage',
    'customer.read',
    'customer.write',
    'customer.payment.create',
  ],
);

/// File hors-ligne en mémoire : les flux Drift ne tournent pas dans le temps
/// simulé des tests d'écran (la vraie file est testée à part).
class _MemoryQueue implements MutationQueue {
  _MemoryQueue({this.tooStale = false, this.pending = 0});

  final bool tooStale;
  final int pending;

  @override
  Future<int> pendingCount({required String authorUserId}) async =>
      pending + queued.length;

  @override
  Future<PendingMutation?> latestPending({
    required String authorUserId,
    required String operationType,
  }) async {
    final last = queued.where((q) => q.type == operationType).lastOrNull;
    if (last == null) return null;
    return PendingMutation(
      clientMutationId: last.key!,
      authorUserId: authorUserId,
      deviceId: 'poste-caisse',
      operationType: last.type,
      payload: jsonEncode(last.payload),
      deviceTimestamp: DateTime.utc(2026, 9, 22, 8),
      status: LocalMutationStatus.enAttente,
      attemptCount: 0,
      createdAt: DateTime.utc(2026, 9, 22, 8),
    );
  }

  final queued = <({String type, Map<String, dynamic> payload, String? key})>[];

  @override
  Future<bool> isTooStale({required String authorUserId}) async => tooStale;

  @override
  Future<String> enqueue({
    required String authorUserId,
    required String deviceId,
    required String operationType,
    required Map<String, dynamic> payload,
    String? clientMutationId,
    DateTime? deviceTimestamp,
  }) async {
    queued.add((type: operationType, payload: payload, key: clientMutationId));
    return clientMutationId!;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _pumpScreen(
  WidgetTester tester,
  _FakeSalesApi api,
  List<String> printed, {
  _MemoryQueue? queue,
  bool withStore = false,
  MemorySettingsStore? settings,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        salesApiProvider.overrideWithValue(api),
        currentUserIdProvider.overrideWithValue('v'),
        deviceIdProvider.overrideWith((ref) async => 'poste-caisse'),
        mutationQueueProvider.overrideWithValue(queue ?? _MemoryQueue()),
        localSettingsStoreProvider.overrideWithValue(
          settings ?? MemorySettingsStore(),
        ),
        printPdfProvider.overrideWithValue((bytes, name) async {
          printed.add('$name:${String.fromCharCodes(bytes.take(5))}');
        }),
        activeProductsProvider.overrideWith((ref) => Stream.value([_cable()])),
        locationsProvider.overrideWith(
          (ref) => Stream.value(withStore ? [_store()] : const []),
        ),
        priceTiersProvider.overrideWith(
          (ref) async => const [
            PriceTier(
              id: 'detail',
              code: 'DETAIL',
              name: 'Détail',
              isDefault: true,
            ),
          ],
        ),
        taxRatesProvider.overrideWith(
          (ref) => Stream.value([
            TaxRate(
              id: 'tva19',
              code: 'TVA19',
              name: 'TVA 19 %',
              rate: '19.00',
              isDefault: true,
              isActive: true,
              updatedAt: DateTime.utc(2026),
            ),
          ]),
        ),
      ],
      child: MaterialApp(
        theme: AppTheme.mobile(dark: true),
        home: Scaffold(body: SalesScreen(user: _vendeur())),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _scanTwiceAndPay(WidgetTester tester) async {
  for (var i = 0; i < 2; i++) {
    await tester.enterText(find.byType(TextField).first, '3245060123458');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
  }
  await tester.tap(find.textContaining('Encaisser 3'));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField).last, '4000');
  await tester.tap(find.text('Valider la vente'));
  await tester.pumpAndSettle();
}

void main() {
  test('estimation du panier : mêmes règles et même arrondi que le serveur', () {
    // Référence e2e serveur : 2,5 × 1 450,00 HT, TVA 19 % → 3 625,00 / 688,75.
    final cart = CartState(
      saleId: 's',
      lines: [CartLine(_cable(), Decimal.parse('2.5'))],
    );
    final estimate = estimateCart(
      cart,
      defaultTierId: 'detail',
      taxRates: {'tva19': Decimal.fromInt(19)},
    );
    expect(
      (estimate.totalHt, estimate.totalTax, estimate.totalTtc),
      (362500, 68875, 431375),
    );
    expect(estimate.lineTotalsHt, {'p1': 362500});

    // Tarif sans prix pour ce produit : signalé, jamais inventé.
    final gros = estimateCart(cart, defaultTierId: 'gros', taxRates: const {});
    expect(gros.missingPrices, hasLength(1));
    expect(gros.totalTtc, 0);
  });

  testWidgets(
    'douchette → panier → encaissement : produit + quantité, monnaie rendue',
    (tester) async {
      useScreenSize(tester, const Size(500, 1400));
      final api = _FakeSalesApi(cash: _openCash);
      final printed = <String>[];
      await _pumpScreen(tester, api, printed);

      // La douchette tape le code puis « Entrée », deux fois + une quantité.
      for (var i = 0; i < 2; i++) {
        await tester.enterText(find.byType(TextField).first, '3245060123458');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();
      }
      expect(find.text('Câble 3G2,5'), findsOneWidget);
      expect(find.text('2 pce'), findsOneWidget);

      // 2 × 1 450,00 × 1,19 = 3 451,00 DA TTC
      expect(find.textContaining('Encaisser 3'), findsOneWidget);
      await tester.tap(find.textContaining('Encaisser 3'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, '4000');
      await tester.tap(find.text('Valider la vente'));
      await tester.pumpAndSettle();

      expect(api.sent!['paidAmount'], 345100);
      // Le serveur refusera si le total a changé depuis l'affichage.
      expect(api.sent!['expectedTotalTtc'], 345100);
      expect(api.sent!['lines'], [
        {'productId': 'p1', 'quantity': '2.000'},
      ]);
      expect(api.sent!.containsKey('unitPriceHt'), isFalse);
      expect(find.textContaining('Monnaie à rendre'), findsOneWidget);

      // Le ticket PDF (généré serveur) part vers l'impression / le partage.
      await tester.tap(find.text('Imprimer le ticket'));
      await tester.pumpAndSettle();
      expect(printed, ['TK-2026-000042.pdf:%PDF-']);
    },
  );

  testWidgets(
    'vente déjà enregistrée avec un autre panier : message, panier vidé (nouvel id)',
    (tester) async {
      useScreenSize(tester, const Size(500, 1400));
      final api = _FakeSalesApi(
        cash: _openCash,
        failure: const ApiException(
          statusCode: 409,
          code: 'SALE_ALREADY_RECORDED',
          message: 'Vente déjà enregistrée : TK-2026-000041 (3 451,00 DA)',
        ),
      );
      await _pumpScreen(tester, api, []);
      await _scanTwiceAndPay(tester);
      final firstId = api.sent!['id'];

      expect(find.textContaining('TK-2026-000041'), findsOneWidget);
      expect(find.textContaining('Encaisser'), findsNothing);

      // Le panier suivant ne réutilise JAMAIS l'id de la vente existante.
      await _scanTwiceAndPay(tester);
      expect(api.sent!['id'], isNot(firstId));
    },
  );

  testWidgets(
    'sans réseau : la vente part dans la file (même corps), reçu « en attente », '
    'jamais un ticket',
    (tester) async {
      useScreenSize(tester, const Size(500, 1400));
      final queue = _MemoryQueue();
      final api = _FakeSalesApi(
        cash: _openCash,
        failure: const ApiException(statusCode: 0, message: 'hors ligne'),
      );
      await _pumpScreen(tester, api, [], queue: queue);
      await _scanTwiceAndPay(tester);

      expect(queue.queued, hasLength(1));
      final queued = queue.queued.single;
      expect(queued.type, 'SALE');
      expect(queued.payload, api.sent, reason: 'même corps qu’en ligne');
      expect(queued.key, queued.payload['clientMutationId']);
      expect(queued.payload['expectedTotalTtc'], 345100);
      expect(
        queued.payload['cashSessionId'],
        _openCash.id,
        reason: 'les espèces restent dans la caisse de la vente',
      );
      expect(find.text('Vente en attente de synchronisation'), findsOneWidget);
      expect(find.textContaining('Monnaie à rendre'), findsOneWidget);
      expect(find.text('Imprimer le ticket'), findsNothing);

      await tester.tap(find.text('Compris'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Encaisser'), findsNothing, reason: 'vidé');
    },
  );

  testWidgets(
    'trop longtemps hors ligne : la vente n’est PAS mise en file, le panier reste',
    (tester) async {
      useScreenSize(tester, const Size(500, 1400));
      final queue = _MemoryQueue(tooStale: true);
      final api = _FakeSalesApi(
        cash: _openCash,
        failure: const ApiException(statusCode: 0, message: 'hors ligne'),
      );
      await _pumpScreen(tester, api, [], queue: queue);
      await _scanTwiceAndPay(tester);

      expect(queue.queued, isEmpty);
      expect(find.textContaining('Trop longtemps hors ligne'), findsOneWidget);
      expect(find.textContaining('Encaisser 3'), findsOneWidget);
    },
  );

  testWidgets(
    'caisse connue FERMÉE : l’encaissement comptoir est bloqué avant tout envoi',
    (tester) async {
      useScreenSize(tester, const Size(500, 1400));
      final api = _FakeSalesApi();
      await _pumpScreen(tester, api, []);
      for (var i = 0; i < 2; i++) {
        await tester.enterText(find.byType(TextField).first, '3245060123458');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();
      }
      await tester.tap(find.textContaining('Encaisser 3'));
      await tester.pumpAndSettle();

      expect(api.sent, isNull);
      expect(find.text('Valider la vente'), findsNothing);
    },
  );

  testWidgets(
    'clôture avec des ventes encore en file : elle part PAR LA FILE, derrière '
    'elles — jamais en ligne avant elles',
    (tester) async {
      useScreenSize(tester, const Size(500, 1400));
      final api = _FakeSalesApi(cash: _openCash);
      final queue = _MemoryQueue(pending: 2);
      await _pumpScreen(tester, api, [], queue: queue);
      await tester.tap(find.text('Clôturer').first);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, '5000');
      await tester.tap(find.text('Clôturer').last);
      await tester.pumpAndSettle();

      expect(api.cashCalls, isEmpty, reason: 'aucun essai en ligne');
      expect(queue.queued.single.type, 'CASH_SESSION');
      expect(queue.queued.single.payload, {
        'action': 'CLOSE',
        'clientMutationId': queue.queued.single.key,
        'sessionId': _openCash.id,
        'countedAmount': 500000,
      });
      expect(
        find.text('Clôture en attente de synchronisation'),
        findsOneWidget,
      );
      await tester.tap(find.text('Compris'));
      await tester.pumpAndSettle();
      // Le serveur la dit encore ouverte (file pas partie) : l'appareil, lui,
      // la sait fermée — plus d'encaissement dedans.
      expect(find.text('Ouvrir la caisse'), findsOneWidget);
    },
  );

  testWidgets(
    'journée sans réseau : caisse ouverte sur l’appareil, la vente suivante '
    'désigne CETTE caisse',
    (tester) async {
      useScreenSize(tester, const Size(500, 1400));
      final api = _FakeSalesApi(
        offline: true,
        failure: const ApiException(statusCode: 0, message: 'hors ligne'),
      );
      final queue = _MemoryQueue();
      // Dernier état connu du serveur : aucune caisse ouverte.
      final settings = MemorySettingsStore()..values['cash-session.v'] = 'none';
      await _pumpScreen(
        tester,
        api,
        [],
        queue: queue,
        withStore: true,
        settings: settings,
      );

      await tester.tap(find.text('Ouvrir la caisse'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, '5000');
      await tester.tap(find.text('Ouvrir'));
      await tester.pumpAndSettle();

      final open = queue.queued.single;
      expect(open.type, 'CASH_SESSION');
      expect(open.payload['action'], 'OPEN');
      expect(open.payload['id'], open.key);
      expect(
        find.text('Caisse ouverte · en attente de synchronisation'),
        findsOneWidget,
      );

      await _scanTwiceAndPay(tester);
      final sale = queue.queued.last;
      expect(sale.type, 'SALE');
      expect(sale.payload['cashSessionId'], open.payload['id']);
    },
  );

  testWidgets(
    'redémarrage hors ligne : la caisse ouverte le matin reste connue — pas de '
    'seconde ouverture proposée',
    (tester) async {
      useScreenSize(tester, const Size(500, 1400));
      final settings = MemorySettingsStore();
      // En ligne le matin : la caisse lue au serveur est mémorisée.
      await _pumpScreen(
        tester,
        _FakeSalesApi(cash: _openCash),
        [],
        settings: settings,
      );
      expect(settings.values['cash-session.v'], contains(_openCash.id));

      // Plus tard, hors ligne après redémarrage.
      await _pumpScreen(
        tester,
        _FakeSalesApi(offline: true),
        [],
        settings: settings,
      );
      expect(find.textContaining('Caisse ouverte'), findsOneWidget);
      expect(find.text('Ouvrir la caisse'), findsNothing);
    },
  );

  testWidgets(
    'hors ligne, caisse jamais lue sur cet appareil : aucune ouverture proposée',
    (tester) async {
      useScreenSize(tester, const Size(500, 1400));
      await _pumpScreen(tester, _FakeSalesApi(offline: true), []);
      expect(find.text('Caisse indisponible'), findsOneWidget);
      expect(find.text('Ouvrir la caisse'), findsNothing);
    },
  );

  test(
    'menu : « Vente » pour ADMIN/VENDEUR avec sale.create, jamais le magasinier',
    () {
      expect(
        destinationsFor(_vendeur()).map((d) => d.label),
        contains('Vente'),
      );
      expect(
        destinationsFor(
          authUser(
            roles: const ['MAGASINIER'],
            permissions: const ['sale.create'],
          ),
        ).map((d) => d.label),
        isNot(contains('Vente')),
      );
    },
  );
}
