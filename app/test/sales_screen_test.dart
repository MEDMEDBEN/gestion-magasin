import 'dart:convert';
import 'dart:typed_data';

import 'package:decimal/decimal.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gestion_magasin/ui/widgets/ampere_controls.dart';
import 'package:gestion_magasin/ui/widgets/period_filter.dart';
import 'package:gestion_magasin/core/money.dart';
import 'package:gestion_magasin/data/models/page_meta.dart';
import 'package:gestion_magasin/core/error/api_exception.dart';
import 'package:gestion_magasin/core/providers.dart';
import 'package:gestion_magasin/data/local/app_database.dart';
import 'package:gestion_magasin/data/local/mutation_queue.dart';
import 'package:gestion_magasin/features/auth/data/auth_models.dart';
import 'package:gestion_magasin/features/catalog/application/catalog_controller.dart';
import 'package:gestion_magasin/features/catalog/data/catalog_models.dart';
import 'package:gestion_magasin/features/sales/application/sales_controller.dart';
import 'package:gestion_magasin/features/sales/data/confrere.dart';
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

  /// Client demandé à l'historique des achats (filtre serveur).
  final historyAsked = <String?>[];

  @override
  Future<CashSessionPage> cashSessions({int limit = 100}) async =>
      CashSessionPage(
        data: [
          CashSession(
            id: 'z1',
            userFullName: 'Caissier',
            status: 'CLOTUREE',
            openingFloat: 100000,
            cashSalesAmount: 0,
            cashSalesCount: 0,
            currentAmount: 55000,
            expectedAmount: 55000,
            countedAmount: 55000,
            difference: 0,
            openedAt: DateTime.utc(2026, 9, 28, 8),
          ),
        ],
        meta: PageMeta(page: 1, limit: limit, total: 1),
      );

  @override
  Future<CashSession> cashReport(String id) async =>
      (await cashSessions()).data.single.copyWith(
        movements: [
          CashMovementLine(
            type: 'PRELEVEMENT',
            amount: 50000,
            note: 'Dépôt banque',
            userFullName: 'Admin',
            createdAt: DateTime.utc(2026, 9, 28, 12),
          ),
        ],
      );

  /// Retours envoyés (P1 bis n°21l).
  final returnsSent = <Map<String, dynamic>>[];

  @override
  Future<List<SaleReturn>> saleReturns(String saleId) async => const [];

  @override
  Future<Sale> sale(String id) async => (await sales()).data.single;

  @override
  Future<SaleReturn> createReturn(
    String saleId,
    Map<String, dynamic> body,
  ) async {
    returnsSent.add(body);
    return SaleReturn(
      id: 'r1',
      number: 'RC-2026-00001',
      saleId: saleId,
      refundMethod: body['refundMethod'] as String,
      totalHt: 50000,
      totalTtc: 59500,
      reason: body['reason'] as String,
      createdAt: DateTime.utc(2026, 9, 28),
      lines: const [],
    );
  }

  /// Mouvements de caisse envoyés (P1 bis n°21k).
  final movements = <Map<String, dynamic>>[];

  /// Premier envoi perdu (réponse jamais reçue).
  bool loseNextMovement = false;

  @override
  Future<CashSession> cashMovement(String id, Map<String, dynamic> body) async {
    movements.add(body);
    if (loseNextMovement) {
      loseNextMovement = false;
      throw _noNetwork;
    }
    return cash!.copyWith(currentAmount: cash!.currentAmount - 50000);
  }

  /// Recherches envoyées à l'historique des ventes, et ventes annulées.
  final searches = <String?>[];
  final cancelled = <String>[];

  @override
  Future<Sale> cancelSale(String saleId) async {
    cancelled.add(saleId);
    return (await sales()).data.single;
  }

  /// Champs envoyés à la fiche client (création ou modification).
  Map<String, Object?>? customerSaved;

  @override
  Future<Customer> saveCustomer(String? id, Map<String, Object?> fields) async {
    customerSaved = fields;
    return (await customers()).data.single;
  }

  /// Confrères (2026-10-08) : un seul, à qui je dois 1 500,00 net.
  @override
  Future<List<Confrere>> confreres() async => const [
    Confrere(
      id: 'cf1',
      supplierId: 'sf1',
      name: 'Ali Élec',
      theyOwe: 50000,
      weOwe: 200000,
      net: -150000,
    ),
  ];

  @override
  Future<Customer> customer(String id) async => Customer(
    id: id,
    name: 'Ali Élec',
    creditLimit: 0,
    balanceDue: 50000,
    isActive: true,
    isConfrere: true,
  );

  @override
  Future<CustomerPage> customers({String? query, int limit = 50}) async =>
      CustomerPage(
        data: const [
          Customer(
            id: 'c1',
            name: 'Benali',
            creditLimit: 0,
            balanceDue: 0,
            isActive: true,
          ),
        ],
        meta: PageMeta(page: 1, limit: limit, total: 1),
      );

  @override
  Future<SalePage> sales({
    int limit = 50,
    int page = 1,
    String? customerId,
    String? q,
    String? from,
    String? to,
  }) async {
    historyAsked.add(customerId);
    searches.add(q);
    return SalePage(
      data: [
        Sale(
          id: 's1',
          number: 'TK-2026-000007',
          type: 'TICKET',
          status: cancelled.isEmpty ? 'VALIDEE' : 'ANNULEE',
          customerId: customerId,
          customerName: 'Benali',
          totalHt: 100000,
          totalTax: 19000,
          totalTtc: 119000,
          paidAmount: 19000,
          remainingAmount: 100000,
          lines: [
            SaleLine(
              id: 'l1',
              productId: 'p1',
              quantity: Decimal.fromInt(2),
              unitPriceHt: 50000,
              taxRate: '19.00',
              discountAmount: 0,
              lineTotalHt: 100000,
              lineTaxAmount: 19000,
              lineTotalTtc: 119000,
            ),
          ],
          soldAt: DateTime.utc(2026, 9, 20, 10),
        ),
      ],
      meta: PageMeta(page: 1, limit: limit, total: 1),
    );
  }

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
  // Caisse du JOUR : celle d'un jour passé est close (2026-10-08).
  openedAt: DateTime.now(),
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
      deviceTimestamp: DateTime.now().toUtc(),
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
  Product? product,
  AuthUser? user,
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
        activeProductsProvider.overrideWith(
          (ref) => Stream.value([product ?? _cable()]),
        ),
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
        home: Scaffold(body: SalesScreen(user: user ?? _vendeur())),
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
  await tester.tap(find.textContaining('Encaisser 2'));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField).last, '4000');
  await tester.tap(find.text('Valider la vente'));
  await tester.pumpAndSettle();
}

void main() {
  test(
    'estimation du panier : mêmes règles et même arrondi que le serveur',
    () {
      // Référence e2e serveur : 2,5 × 1 450,00 = 3 625,00, sans TVA
      // (retirée le 2026-10-05) : le total payé est celui des lignes.
      final cart = CartState(
        saleId: 's',
        lines: [CartLine(_cable(), Decimal.parse('2.5'))],
      );
      final estimate = estimateCart(cart, defaultTierId: 'detail');
      expect((estimate.totalHt, estimate.totalTtc), (362500, 362500));
      expect(estimate.lineTotalsHt, {'p1': 362500});

      // Client au tarif GROS désactivé : le tarif par défaut s'applique, comme
      // au serveur (sinon 409 « le tarif a changé » à chaque essai).
      final pro = CartState(
        saleId: 's',
        lines: [CartLine(_cable(), Decimal.one)],
        customer: const Customer(
          id: 'c',
          name: 'Pro',
          priceTierId: 'gros',
          creditLimit: 0,
          balanceDue: 0,
          isActive: true,
        ),
      );
      final grosPrice = _cable().copyWith(
        prices: const [
          ProductPriceLine(priceTierId: 'detail', priceHt: 145000),
          ProductPriceLine(priceTierId: 'gros', priceHt: 120000),
        ],
      );
      final proCart = CartState(
        saleId: 's',
        lines: [CartLine(grosPrice, Decimal.one)],
        customer: pro.customer,
      );
      expect(
        estimateCart(
          proCart,
          defaultTierId: 'detail',
          activeTierIds: const {'detail', 'gros'},
        ).totalHt,
        120000,
      );
      expect(
        estimateCart(
          proCart,
          defaultTierId: 'detail',
          activeTierIds: const {'detail'},
        ).totalHt,
        145000,
      );

      // Borne de la remise = celle du serveur : net ≥ plancher × quantité.
      final costed = _cable().copyWith(lastPurchasePriceHt: 100000);
      final q = Decimal.parse('2.5');
      // 2,5 × 1 450,01 = 3 625,025 → 362 503 (demi vers le haut) ; plancher
      // 2,5 × 1 000 = 250 000 → remise ≤ 112 503.
      expect(maxLineDiscountHt(costed, 145001, q), 112503);
      // Sans coût : plancher = plus bas tarif (1 450,00) ; prix modifié 1 500.
      expect(maxLineDiscountHt(_cable(), 150000, Decimal.one), 5000);
      // Prix sous le plancher : aucune remise, jamais négative.
      expect(maxLineDiscountHt(costed, 90000, Decimal.one), 0);

      // Remise valide à 3, devenue trop forte après baisse à 1 : BLOQUÉE.
      CartEstimate estimateAt(Decimal quantity) => estimateCart(
        CartState(
          saleId: 's',
          lines: [CartLine(costed, quantity, discountHt: 100000)],
        ),
        defaultTierId: 'detail',
      );
      expect(estimateAt(Decimal.fromInt(3)).blocked, isFalse);
      expect(estimateAt(Decimal.one).invalidDiscounts, [costed]);
      expect(estimateAt(Decimal.one).blocked, isTrue);

      // Remise sur la ligne (P1 bis n°21g) : le total est le NET.
      final discounted = estimateCart(
        CartState(
          saleId: 's',
          lines: [CartLine(_cable(), Decimal.parse('2.5'), discountHt: 50000)],
        ),
        defaultTierId: 'detail',
      );
      expect((discounted.totalHt, discounted.totalTtc), (312500, 312500));

      // Tarif sans prix pour ce produit : signalé, jamais inventé.
      final gros = estimateCart(cart, defaultTierId: 'gros');
      expect(gros.missingPrices, hasLength(1));
      expect(gros.totalTtc, 0);
    },
  );

  test('une caisse ne vit qu’un jour : celle d’hier est close (2026-10-08)', () {
    final now = DateTime(2026, 10, 9, 9, 30);
    final today = _openCash.copyWith(openedAt: DateTime(2026, 10, 9, 7));
    final yesterday = _openCash.copyWith(
      openedAt: DateTime(2026, 10, 8, 23, 50),
    );
    expect(todaysCash(today, now), today);
    expect(todaysCash(yesterday, now), isNull);
    expect(todaysCash(null, now), isNull);
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

      // 2 × 1 450,00 = 2 900,00 DA (sans TVA depuis le 2026-10-05)
      expect(find.textContaining('Encaisser 2'), findsOneWidget);
      await tester.tap(find.textContaining('Encaisser 2'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, '4000');
      await tester.tap(find.text('Valider la vente'));
      await tester.pumpAndSettle();

      expect(api.sent!['paidAmount'], 290000);
      // Le serveur refusera si le total a changé depuis l'affichage.
      expect(api.sent!['expectedTotalTtc'], 290000);
      // Le prix APPLIQUÉ part explicitement (prix vu par le client).
      expect(api.sent!['lines'], [
        {'productId': 'p1', 'quantity': '2.000', 'unitPriceHt': 145000},
      ]);
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
      expect(queued.payload['expectedTotalTtc'], 290000);
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
      expect(find.textContaining('Encaisser 2'), findsOneWidget);
    },
  );

  testWidgets(
    'caisse connue FERMÉE : l’encaissement comptoir est bloqué avant tout envoi',
    (tester) async {
      useScreenSize(tester, const Size(500, 1400));
      final api = _FakeSalesApi();
      await _pumpScreen(tester, api, [], withStore: true);
      for (var i = 0; i < 2; i++) {
        await tester.enterText(find.byType(TextField).first, '3245060123458');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();
      }
      // Caisse fermée (2026-10-08) : pas de bouton Encaisser — le bouton
      // principal ouvre la caisse (fond du jour) avant la première vente.
      expect(find.textContaining('Encaisser 2'), findsNothing);
      await tester.tap(find.text('Ouvrir la caisse pour encaisser'));
      await tester.pumpAndSettle();
      expect(find.text('Ouvrir la caisse du jour'), findsOneWidget);

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

  testWidgets(
    'prix modifié sur une ligne : total recalculé, prix envoyé, badge « Prix modifié »',
    (tester) async {
      useScreenSize(tester, const Size(500, 1400));
      final api = _FakeSalesApi(cash: _openCash);
      await _pumpScreen(tester, api, []);
      await tester.enterText(find.byType(TextField).first, '3245060123458');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Modifier le prix'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, '1600');
      await tester.tap(find.text('Appliquer'));
      await tester.pumpAndSettle();

      expect(find.text('Prix modifié'), findsOneWidget);
      // 1 600,00 sans TVA
      await tester.tap(find.textContaining('Encaisser 1'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, '1600');
      await tester.tap(find.text('Valider la vente'));
      await tester.pumpAndSettle();

      expect(api.sent!['lines'], [
        {
          'productId': 'p1',
          'quantity': '1.000',
          'unitPriceHt': 160000,
          'priceEdited': true,
        },
      ]);
      expect(api.sent!['expectedTotalTtc'], 160000);
    },
  );

  testWidgets(
    'prix sous le prix d’achat : refusé à la saisie, le tarif reste appliqué',
    (tester) async {
      useScreenSize(tester, const Size(500, 1400));
      await _pumpScreen(
        tester,
        _FakeSalesApi(cash: _openCash),
        [],
        product: _cable().copyWith(lastPurchasePriceHt: 120000),
      );
      await tester.enterText(find.byType(TextField).first, '3245060123458');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Modifier le prix'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, '1199,99');
      await tester.tap(find.text('Appliquer'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Prix trop bas'), findsOneWidget);
      expect(find.text('Prix modifié'), findsNothing);
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

  /// Caisse desktop (2026-10-06) : catalogue en tuiles, ticket, afficheur.
  testWidgets(
    'caisse large : toucher une tuile ou « Entrée » remplit le ticket',
    (tester) async {
      useScreenSize(tester, const Size(1300, 900));
      await _pumpScreen(tester, _FakeSalesApi(cash: _openCash), []);
      expect(find.text('Panier vide'), findsOneWidget);
      expect(find.text('TOTAL À PAYER'), findsOneWidget);

      // Tuile du catalogue : un toucher = une unité de plus.
      await tester.tap(find.text('Câble 3G2,5'));
      await tester.pumpAndSettle();
      expect(find.text('1 pce'), findsOneWidget);

      // Recherche à un seul résultat, puis Entrée : ajouté, champ vidé.
      await tester.enterText(find.byType(TextField).first, '3g2');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(find.text('2 pce'), findsOneWidget);
      expect(find.textContaining('Encaisser'), findsOneWidget);
    },
  );

  /// Demande MEDMEDBEN du 2026-10-08 : les confrères, depuis l'écran Vente.
  testWidgets('confrères : soldes, « Lui vendre » ouvre la vente sans plafond', (
    tester,
  ) async {
    useScreenSize(tester, const Size(500, 1400));
    await _pumpScreen(tester, _FakeSalesApi(cash: _openCash), []);
    await tester.tap(find.text('Confrères'));
    await tester.pumpAndSettle();
    expect(find.text('Ali Élec'), findsOneWidget);
    expect(find.text('Je lui dois ${formatDA(150000)}'), findsOneWidget);
    // Verser au confrère = paiement fournisseur : pas pour le vendeur.
    expect(find.text('Je le paie'), findsNothing);
    expect(find.text('Lui acheter'), findsOneWidget);
    expect(find.text('Échange'), findsOneWidget);

    await tester.tap(find.text('Lui vendre'));
    await tester.pumpAndSettle();
    expect(find.textContaining('confrère, sans plafond'), findsOneWidget);
  });

  /// Retour de test humain (2026-09-27) : l'historique des achats d'un client
  /// était introuvable depuis sa fiche.
  testWidgets('fiche client : historique des achats, filtré serveur', (
    tester,
  ) async {
    useScreenSize(tester, const Size(500, 1400));
    final api = _FakeSalesApi(cash: _openCash);
    await _pumpScreen(tester, api, []);
    await tester.tap(find.text('Clients'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Benali'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Historique des achats'));
    await tester.pumpAndSettle();

    expect(api.historyAsked.last, 'c1');
    expect(find.text('TK-2026-000007'), findsOneWidget);
    expect(find.textContaining('reste ${formatDA(100000)}'), findsOneWidget);
    expect(find.text(formatDA(119000)), findsOneWidget);
    // Les lignes sont datées : le filtre par période est proposé.
    expect(find.byType(PeriodFilter), findsOneWidget);
  });

  /// Revue du 2026-09-27 : aucune vente passée n'était visible — ni
  /// réimpression, ni facture après coup, ni annulation.
  testWidgets(
    'historique des ventes : recherche serveur, détail, réimpression',
    (tester) async {
      useScreenSize(tester, const Size(900, 1400));
      final api = _FakeSalesApi(cash: _openCash);
      final printed = <String>[];
      await _pumpScreen(tester, api, printed);
      await tester.tap(find.text('Historique'));
      await tester.pumpAndSettle();
      expect(find.text('TK-2026-000007'), findsOneWidget);

      await tester.enterText(find.byType(TextField).last, 'TK-2026-000007');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(api.searches.last, 'TK-2026-000007');

      await tester.tap(find.widgetWithText(ListTile, 'TK-2026-000007'));
      await tester.pumpAndSettle();
      expect(find.text('Réimprimer le ticket'), findsOneWidget);
      expect(find.text('Émettre la facture'), findsOneWidget);
      // Le vendeur n'annule pas une vente (ADMIN + sale.cancel).
      expect(find.text('Annuler la vente'), findsNothing);
      await tester.tap(find.text('Réimprimer le ticket'));
      await tester.pumpAndSettle();
      expect(printed.single, startsWith('TK-2026-000007.pdf'));
    },
  );

  /// Demande MEDMEDBEN du 2026-10-06 : fiche contact, et « Supprimer »
  /// réservé à l'admin (le serveur refuse s'il reste une dette).
  testWidgets('fiche contact client : le vendeur ne supprime pas', (
    tester,
  ) async {
    useScreenSize(tester, const Size(500, 1400));
    await _pumpScreen(tester, _FakeSalesApi(cash: _openCash), []);
    await tester.tap(find.text('Clients'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Benali'));
    await tester.pumpAndSettle();
    expect(find.text('Client'), findsWidgets);
    expect(find.text('Reste dû'), findsOneWidget);
    expect(find.text('Supprimer'), findsNothing);
  });

  testWidgets('fiche contact client : l’admin supprime, après confirmation', (
    tester,
  ) async {
    useScreenSize(tester, const Size(500, 1400));
    final api = _FakeSalesApi(cash: _openCash);
    final admin = authUser(
      id: 'a',
      roles: const ['ADMIN'],
      permissions: const ['sale.create', 'customer.read', 'customer.write'],
    );
    await _pumpScreen(tester, api, [], user: admin);
    await tester.tap(find.text('Clients'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Benali'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(AmpereDangerButton, 'Supprimer'));
    await tester.pumpAndSettle();
    expect(api.customerSaved, isNull); // rien sans confirmation
    expect(find.text('Supprimer « Benali » ?'), findsOneWidget);
    await tester.tap(find.widgetWithText(AmpereDangerButton, 'Supprimer').last);
    await tester.pumpAndSettle();
    expect(api.customerSaved, {'isActive': false});
  });

  testWidgets('historique : l’admin annule une vente, après confirmation', (
    tester,
  ) async {
    useScreenSize(tester, const Size(900, 1400));
    final api = _FakeSalesApi(cash: _openCash);
    final admin = authUser(
      id: 'a',
      roles: const ['ADMIN'],
      permissions: const ['sale.create', 'sale.cancel', 'cash.report.read'],
    );
    await _pumpScreen(tester, api, [], user: admin);
    await tester.tap(find.text('Historique'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('TK-2026-000007'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Annuler la vente'));
    await tester.pumpAndSettle();
    expect(api.cancelled, isEmpty); // rien sans confirmation
    await tester.tap(find.widgetWithText(FilledButton, 'Annuler la vente'));
    await tester.pumpAndSettle();
    expect(api.cancelled, ['s1']);
    expect(find.textContaining('Annulée'), findsWidgets);
  });

  /// P1 bis n°21g : la remise existait au serveur, sans aucune saisie.
  testWidgets('remise ADMIN : bornée au coût, envoyée au serveur', (
    tester,
  ) async {
    useScreenSize(tester, const Size(900, 1400));
    final api = _FakeSalesApi(cash: _openCash);
    final admin = authUser(
      id: 'a',
      roles: const ['ADMIN'],
      permissions: const [
        'sale.create',
        'sale.discount',
        'cash.session.manage',
      ],
    );
    await _pumpScreen(
      tester,
      api,
      [],
      user: admin,
      product: _cable().copyWith(lastPurchasePriceHt: 100000),
    );
    await tester.enterText(find.byType(TextField).first, '3245060123458');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    // Le prix d'achat est sur la ligne (2026-10-05) : savoir jusqu'où baisser.
    expect(find.textContaining('achat ${formatDA(100000)}'), findsOneWidget);

    // Au-delà de ligne − coût (1 450 − 1 000 = 450 DA) : refusé.
    await tester.tap(find.byTooltip('Remise'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '500');
    await tester.tap(find.text('Appliquer'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Remise trop forte'), findsOneWidget);

    await tester.tap(find.byTooltip('Remise'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '100');
    await tester.tap(find.text('Appliquer'));
    await tester.pumpAndSettle();
    expect(find.text('Remise ${formatDA(10000)}'), findsOneWidget);

    await tester.tap(find.textContaining('Encaisser'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '4000');
    await tester.tap(find.text('Valider la vente'));
    await tester.pumpAndSettle();
    final line = (api.sent!['lines']! as List).single as Map;
    expect(line['discountAmount'], 10000);
  });

  testWidgets('le VENDEUR n’a pas de bouton de remise', (tester) async {
    useScreenSize(tester, const Size(900, 1400));
    await _pumpScreen(tester, _FakeSalesApi(cash: _openCash), []);
    await tester.enterText(find.byType(TextField).first, '3245060123458');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Modifier le prix'), findsOneWidget);
    expect(find.byTooltip('Remise'), findsNothing);
  });

  testWidgets('remise puis quantité baissée : encaissement bloqué, signalé', (
    tester,
  ) async {
    useScreenSize(tester, const Size(900, 1400));
    final admin = authUser(
      id: 'a',
      roles: const ['ADMIN'],
      permissions: const [
        'sale.create',
        'sale.discount',
        'cash.session.manage',
      ],
    );
    await _pumpScreen(
      tester,
      _FakeSalesApi(cash: _openCash),
      [],
      user: admin,
      product: _cable().copyWith(lastPurchasePriceHt: 100000),
    );
    for (var i = 0; i < 3; i++) {
      await tester.enterText(find.byType(TextField).first, '3245060123458');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
    }
    // 3 × (1 450 − 1 000) = 1 350 DA : la remise maximale.
    await tester.tap(find.byTooltip('Remise'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '1350');
    await tester.tap(find.text('Appliquer'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Moins'));
    await tester.pumpAndSettle();

    expect(find.textContaining('trop forte — à corriger'), findsOneWidget);
    final pay = tester.widget<FilledButton>(
      find.ancestor(
        of: find.textContaining('Encaisser'),
        matching: find.byType(FilledButton),
      ),
    );
    expect(pay.onPressed, isNull);

    // Retirer la remise (0) est toujours permis, et débloque.
    await tester.tap(find.byTooltip('Remise'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '0');
    await tester.tap(find.text('Appliquer'));
    await tester.pumpAndSettle();
    expect(find.textContaining('trop forte'), findsNothing);
  });

  /// P1 bis n°21k : entrée / sortie / prélèvement, avec motif, en ligne.
  testWidgets('caisse : prélèvement avec motif, clé d’idempotence envoyée', (
    tester,
  ) async {
    useScreenSize(tester, const Size(900, 1400));
    final api = _FakeSalesApi(cash: _openCash);
    await _pumpScreen(tester, api, []);
    await tester.tap(find.byTooltip('Mouvement de caisse'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Prélèvement (coffre, banque)'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '500');
    await tester.tap(find.text('Continuer'));
    await tester.pumpAndSettle();
    // Sans motif : refusé à l'écran, rien d'envoyé.
    await tester.tap(find.text('Enregistrer'));
    await tester.pumpAndSettle();
    expect(find.text('Motif obligatoire'), findsOneWidget);
    expect(api.movements, isEmpty);

    await tester.tap(find.byTooltip('Mouvement de caisse'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Prélèvement (coffre, banque)'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '500');
    await tester.tap(find.text('Continuer'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Dépôt banque');
    await tester.tap(find.text('Enregistrer'));
    await tester.pumpAndSettle();
    expect(api.movements.single, {
      'clientMutationId': isA<String>(),
      'type': 'PRELEVEMENT',
      'amount': 50000,
      'note': 'Dépôt banque',
    });
  });

  /// Audit 21k : une sortie qui couvrirait un écart doit SE VOIR au rapport Z.
  testWidgets('rapport Z (admin) : chaque mouvement, son auteur, son motif', (
    tester,
  ) async {
    useScreenSize(tester, const Size(900, 1400));
    final admin = authUser(
      id: 'a',
      roles: const ['ADMIN'],
      permissions: const ['sale.create', 'cash.report.read'],
    );
    await _pumpScreen(tester, _FakeSalesApi(cash: _openCash), [], user: admin);
    await tester.tap(find.text('Caisses'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Caissier'));
    await tester.pumpAndSettle();
    expect(find.text('Mouvements hors vente'), findsOneWidget);
    expect(find.textContaining('Prélèvement'), findsOneWidget);
    expect(find.textContaining('Admin · Dépôt banque'), findsOneWidget);
  });

  /// Revue 21k : la clé ne dépend ni du montant ni du motif, ressaisis au
  /// nouvel essai — sinon une sortie perdue sur le réseau passerait DEUX fois.
  test(
    'mouvement de caisse : même clé au nouvel essai, motif retapé',
    () async {
      final api = _FakeSalesApi(cash: _openCash)..loseNextMovement = true;
      final container = ProviderContainer(
        overrides: [
          salesApiProvider.overrideWithValue(api),
          currentUserIdProvider.overrideWithValue('v'),
        ],
      );
      addTearDown(container.dispose);
      final actions = container.read(salesActionsProvider);
      await expectLater(
        actions.cashMovement(
          'cash',
          type: 'SORTIE',
          amount: 50000,
          note: 'Dépôt banque',
        ),
        throwsA(isA<ApiException>()),
      );
      await actions.cashMovement(
        'cash',
        type: 'SORTIE',
        amount: 50000,
        note: 'depot banque',
      );
      expect(
        api.movements[1]['clientMutationId'],
        api.movements[0]['clientMutationId'],
      );
    },
  );

  /// P1 bis n°21l : retour partiel depuis l'historique (ADMIN).
  testWidgets('retour d’articles : quantité bornée, motif, envoyé au serveur', (
    tester,
  ) async {
    useScreenSize(tester, const Size(900, 1400));
    final api = _FakeSalesApi(cash: _openCash);
    final admin = authUser(
      id: 'a',
      roles: const ['ADMIN'],
      permissions: const ['sale.create', 'sale.cancel'],
    );
    await _pumpScreen(tester, api, [], user: admin);
    await tester.tap(find.text('Historique'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'TK-2026-000007'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Retour d’articles'));
    await tester.pumpAndSettle();
    expect(find.textContaining('rendable 2'), findsOneWidget);

    // Plus que vendu : refusé à l'écran.
    await tester.enterText(find.byType(TextField).at(1), '3');
    await tester.enterText(find.byType(TextField).last, 'Défaut');
    await tester.tap(find.text('Enregistrer le retour'));
    await tester.pumpAndSettle();
    expect(find.text('Quantité invalide sur une ligne'), findsOneWidget);
    expect(api.returnsSent, isEmpty);

    await tester.enterText(find.byType(TextField).at(1), '1');
    await tester.tap(find.text('Enregistrer le retour'));
    await tester.pumpAndSettle();
    final sent = api.returnsSent.single;
    expect(sent['lines'], [
      {'saleLineId': 'l1', 'quantity': '1.000'},
    ]);
    expect(sent['reason'], 'Défaut');
    // Vente à crédit avec un reste dû : déduction de la dette par défaut.
    expect(sent['refundMethod'], 'DETTE');
    expect(sent['clientMutationId'], isA<String>());
    expect(
      find.textContaining('Retour RC-2026-00001 enregistré'),
      findsOneWidget,
    );
  });
}
