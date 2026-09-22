import 'dart:convert';

import 'package:decimal/decimal.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:printing/printing.dart';

import '../../../core/dates.dart';
import '../../../core/error/error_codes.dart';
import '../../../core/error/api_exception.dart';
import '../../../core/mutation_keys.dart';
import '../../../core/offline_write.dart';
import '../../../core/providers.dart';
import '../../../core/quantity.dart';
import '../../../data/sync/sync_coordinator.dart';
import '../../catalog/application/catalog_controller.dart';
import '../../catalog/data/catalog_models.dart';
import '../../payments/data/payment_models.dart';
import '../data/sales_api.dart';
import '../data/sales_models.dart';

/// Statut local d'une caisse ouverte sur cet appareil et pas encore connue du
/// serveur : jamais présentée comme définitive (règle 8).
const cashPendingSync = 'EN_ATTENTE';

/// Caisse ouverte du compte connecté (`null` : aucune). Trois sources, par
/// ordre de priorité :
/// 1. la FILE : la dernière ouverture/clôture de caisse de ce compte encore en
///    attente fait foi (le serveur ne la connaît pas encore). Un rejet ou une
///    confirmation la sort de la file : l'état se recale tout seul ;
/// 2. le SERVEUR, lu en ligne, dont la réponse est conservée sur l'appareil ;
/// 3. hors ligne, ce DERNIER ÉTAT CONNU — même après un redémarrage. Jamais
///    connu : erreur (caisse inconnue) — on ne propose alors pas d'en ouvrir
///    une, elle pourrait déjà l'être au serveur (audit tranche C).
final currentCashSessionProvider = FutureProvider.autoDispose<CashSession?>((
  ref,
) async {
  final userId = ref.watch(currentUserIdProvider);
  if (userId == null) return null;
  // Recalcul à chaque mouvement de la file (mise en file, synchro, rejet).
  ref.watch(pendingMutationsCountProvider);
  final queued = await ref
      .watch(mutationQueueProvider)
      .latestPending(authorUserId: userId, operationType: 'CASH_SESSION');
  if (queued != null) {
    final body = jsonDecode(queued.payload) as Map<String, dynamic>;
    if (body['action'] == 'CLOSE') return null;
    return CashSession(
      id: body['id'] as String,
      status: cashPendingSync,
      openingFloat: body['openingFloat'] as int,
      cashSalesAmount: 0,
      cashSalesCount: 0,
      currentAmount: body['openingFloat'] as int,
      openedAt: queued.deviceTimestamp,
    );
  }
  final settings = ref.watch(localSettingsStoreProvider);
  final memoryKey = 'cash-session.$userId';
  try {
    final server = await ref.watch(salesApiProvider).currentCashSession();
    await settings.write(
      memoryKey,
      server == null ? 'none' : jsonEncode(server.toJson()),
    );
    return server;
  } on ApiException catch (error) {
    final known = error.isOffline ? await settings.read(memoryKey) : null;
    if (known == null) rethrow;
    return known == 'none'
        ? null
        : CashSession.fromJson(jsonDecode(known) as Map<String, dynamic>);
  }
});

final customerSearchProvider = FutureProvider.autoDispose
    .family<List<Customer>, String>((ref, query) async {
      ref.watch(currentUserIdProvider);
      final page = await ref
          .watch(salesApiProvider)
          .customers(query: query.isEmpty ? null : query);
      return page.data;
    });

final mySalesProvider = FutureProvider.autoDispose<List<Sale>>((ref) async {
  ref.watch(currentUserIdProvider);
  return (await ref.watch(salesApiProvider).sales()).data;
});

@immutable
class CartLine {
  const CartLine(this.product, this.quantity);

  final Product product;
  final Quantity quantity;
}

/// Panier en cours. Il vit côté client jusqu'à la validation (pas de brouillon
/// serveur, docs/plan.md). `saleId` est généré avec le panier : un renvoi après
/// coupure réutilise le même id et le serveur ne crée pas de seconde vente.
@immutable
class CartState {
  const CartState({required this.saleId, this.lines = const [], this.customer});

  final String saleId;
  final List<CartLine> lines;
  final Customer? customer;

  bool get isEmpty => lines.isEmpty;

  CartState copyWith({
    List<CartLine>? lines,
    ValueGetter<Customer?>? customer,
  }) => CartState(
    saleId: saleId,
    lines: lines ?? this.lines,
    customer: customer != null ? customer() : this.customer,
  );
}

class CartController extends Notifier<CartState> {
  @override
  CartState build() {
    ref.watch(currentUserIdProvider);
    return CartState(saleId: ref.read(uuidProvider).v7());
  }

  /// Ajout (recherche ou douchette) : un même produit s'additionne sur sa ligne.
  void add(Product product, [Quantity? quantity]) {
    final added = quantity ?? Quantity.one;
    final lines = [...state.lines];
    final index = lines.indexWhere((l) => l.product.id == product.id);
    if (index >= 0) {
      lines[index] = CartLine(product, lines[index].quantity + added);
    } else {
      lines.add(CartLine(product, added));
    }
    state = state.copyWith(lines: lines);
  }

  void setQuantity(String productId, Quantity quantity) {
    state = state.copyWith(
      lines: [
        for (final line in state.lines)
          if (line.product.id != productId)
            line
          else if (quantity > Quantity.zero)
            CartLine(line.product, quantity),
      ],
    );
  }

  void setCustomer(Customer? customer) =>
      state = state.copyWith(customer: () => customer);

  /// Nouveau panier, nouvel identifiant de vente.
  void clear() => state = CartState(saleId: ref.read(uuidProvider).v7());
}

final cartProvider = NotifierProvider<CartController, CartState>(
  CartController.new,
);

/// Estimation affichée pendant la saisie, avec les MÊMES règles que le serveur
/// (prix du tarif du client ou par défaut, TVA, arrondi au centime demi-haut).
/// Le serveur recalcule et fait foi : cette valeur n'est jamais envoyée.
@immutable
class CartEstimate {
  const CartEstimate({
    required this.totalHt,
    required this.totalTax,
    required this.missingPrices,
    this.lineTotalsHt = const {},
  });

  final int totalHt;
  final int totalTax;
  int get totalTtc => totalHt + totalTax;

  /// Produits sans prix pour le tarif applicable : la vente serait refusée.
  final List<Product> missingPrices;

  /// Total HT estimé par produit (affiché sur chaque ligne du panier).
  final Map<String, int> lineTotalsHt;
}

int _roundMoney(Decimal value) =>
    value.round(scale: 0).toBigInt().toInt(); // demi vers le haut (positif)

CartEstimate estimateCart(
  CartState cart, {
  required String? defaultTierId,
  required Map<String, Decimal> taxRates,
}) {
  final tierId = cart.customer?.priceTierId ?? defaultTierId;
  var ht = 0;
  var tax = 0;
  final missing = <Product>[];
  final lineTotals = <String, int>{};
  for (final line in cart.lines) {
    final price = line.product.prices
        .where((p) => p.priceTierId == tierId)
        .firstOrNull;
    if (price == null) {
      missing.add(line.product);
      continue;
    }
    final lineHt = _roundMoney(Decimal.fromInt(price.priceHt) * line.quantity);
    final rate = taxRates[line.product.taxRateId] ?? Decimal.zero;
    lineTotals[line.product.id] = lineHt;
    ht += lineHt;
    tax += _roundMoney(
      (Decimal.fromInt(lineHt) * rate / Decimal.fromInt(100)).toDecimal(
        scaleOnInfinitePrecision: 6,
      ),
    );
  }
  return CartEstimate(
    totalHt: ht,
    totalTax: tax,
    missingPrices: missing,
    lineTotalsHt: lineTotals,
  );
}

final cartEstimateProvider = Provider.autoDispose<CartEstimate>((ref) {
  final tiers = ref.watch(priceTiersProvider).value ?? const <PriceTier>[];
  final rates = ref.watch(taxRatesProvider).value ?? const <TaxRate>[];
  return estimateCart(
    ref.watch(cartProvider),
    defaultTierId: tiers.where((t) => t.isDefault).firstOrNull?.id,
    taxRates: {for (final r in rates) r.id: Decimal.parse(r.rate)},
  );
});

/// Impression / partage d'un PDF (boîte système : imprimante, « Enregistrer en
/// PDF », partage mobile). Remplaçable en test.
final printPdfProvider =
    Provider<Future<void> Function(Uint8List bytes, String name)>(
      (ref) =>
          (bytes, name) =>
              Printing.layoutPdf(onLayout: (_) async => bytes, name: name),
    );

/// Toutes les caisses (ADMIN), les plus récentes d'abord.
final cashSessionsProvider = FutureProvider.autoDispose<List<CashSession>>((
  ref,
) async {
  ref.watch(currentUserIdProvider);
  return (await ref.watch(salesApiProvider).cashSessions()).data;
});

/// Écritures Caisse / Ventes / Clients — toujours validées par le serveur.
class SalesActions {
  SalesActions(this._ref);

  final Ref _ref;

  SalesApi get _api => _ref.read(salesApiProvider);

  /// Ouverture : en ligne si possible, sinon par la file. L'id de la caisse est
  /// la clé de l'intention (stable d'un essai à l'autre) : une caisse ouverte
  /// HORS LIGNE est désignée par les ventes suivantes avant d'exister au serveur.
  Future<WriteOutcome<CashSession>> openCash(
    String storeId,
    int openingFloat,
  ) async {
    final outcome = await writeOnlineOrQueue<CashSession>(
      _ref,
      // Exception motivée à la règle « une intention = une opération » : un
      // compte n'a qu'UNE caisse ouverte à la fois, et la clé est libérée dès
      // l'ouverture faite ou mise en file.
      intent: 'cash-open',
      operationType: 'CASH_SESSION',
      payload: (key) => {
        'action': 'OPEN',
        'clientMutationId': key,
        'id': key,
        'locationId': storeId,
        'openingFloat': openingFloat,
      },
      online: (body) => _api.openCashSession(_withoutAction(body)),
    );
    // En file : `currentCashSessionProvider` la lit dans la file elle-même.
    _ref.invalidate(currentCashSessionProvider);
    return outcome;
  }

  /// Clôture (rapport Z). S'il reste des opérations de ce compte en file (ventes
  /// hors-ligne), on tente d'abord de les synchroniser ; si elles attendent
  /// encore, la clôture passe PAR LA FILE, derrière elles : le serveur les
  /// compte dans l'attendu. Clôturer en ligne avant elles fausserait le rapport
  /// Z et ferait refuser ces ventes (`CASH_SESSION_CLOSED`).
  Future<WriteOutcome<CashSession>> closeCash(
    String sessionId,
    int countedAmount,
  ) async {
    final behindQueue = await _pendingAfterSync() > 0;
    final outcome = await writeOnlineOrQueue<CashSession>(
      _ref,
      intent: 'cash-close:$sessionId',
      operationType: 'CASH_SESSION',
      payload: (key) => {
        'action': 'CLOSE',
        'clientMutationId': key,
        'sessionId': sessionId,
        'countedAmount': countedAmount,
      },
      online: (body) {
        final route = _withoutAction(body)..remove('sessionId');
        return _api.closeCashSession(sessionId, route);
      },
      queueOnly: behindQueue,
      // Fermer son tiroir reste possible après une longue coupure.
      staleGuard: false,
    );
    _ref.invalidate(currentCashSessionProvider);
    return outcome;
  }

  Future<int> _pendingAfterSync() async {
    final userId = _ref.read(currentUserIdProvider);
    if (userId == null) return 0;
    final queue = _ref.read(mutationQueueProvider);
    if (await queue.pendingCount(authorUserId: userId) == 0) return 0;
    await _ref.read(syncCoordinatorProvider.notifier).kick();
    return queue.pendingCount(authorUserId: userId);
  }

  /// `action` n'existe que dans la file (le handler aiguille OPEN / CLOSE) ;
  /// les routes en ligne refusent un champ inconnu.
  static Map<String, dynamic> _withoutAction(Map<String, dynamic> body) =>
      {...body}..remove('action');

  /// Valide le panier. `paidAmount` : espèces GARDÉES (≤ total) ; le reste
  /// part en crédit client. Le panier n'est vidé qu'après succès — vente
  /// confirmée (`Applied`) OU mise en file hors-ligne (`Queued`, un TICKET que
  /// le serveur jugera à la synchronisation : jamais présenté comme définitif).
  /// `expectedTotalTtc` : le total annoncé au client ; le serveur refuse (409)
  /// s'il a changé, pour ne jamais encaisser ou rendre la monnaie sur un faux total.
  /// `dueDate` : échéance OBLIGATOIRE dès qu'une partie reste à crédit.
  Future<WriteOutcome<Sale>> checkout(
    int paidAmount, {
    required int expectedTotalTtc,
    DateTime? dueDate,
  }) async {
    final cart = _ref.read(cartProvider);
    // Caisse où entrent les espèces (dernier état lu, même hors ligne) : le
    // serveur refuse si ce n'est plus la caisse ouverte — les espèces ne
    // passent jamais dans une autre caisse (audit sécu tranche B).
    // Sans espèces (crédit), aucune caisse en jeu.
    final cash = paidAmount > 0
        ? _ref.read(currentCashSessionProvider).value
        : null;
    if (paidAmount > 0 && cash == null) {
      throw const ApiException(
        statusCode: 409,
        code: ErrorCodes.cashSessionRequired,
        message: 'Ouvrez la caisse avant d’encaisser des espèces',
      );
    }
    // L'intention « valider CE panier » garde sa clé jusqu'au succès.
    final outcome = await writeOnlineOrQueue<Sale>(
      _ref,
      intent: 'sale:${cart.saleId}',
      operationType: 'SALE',
      payload: (key) => SalesApi.saleBody(
        clientMutationId: key,
        id: cart.saleId,
        customerId: cart.customer?.id,
        cashSessionId: paidAmount > 0 ? cash!.id : null,
        lines: [
          for (final line in cart.lines)
            (
              productId: line.product.id,
              quantity: quantityToJson(line.quantity),
            ),
        ],
        paidAmount: paidAmount,
        expectedTotalTtc: expectedTotalTtc,
        dueDate: dueDate == null ? null : isoDay(dueDate),
      ),
      online: _api.createSale,
      // Caisse encore en file : la vente doit passer APRÈS son ouverture.
      queueOnly: cash?.status == cashPendingSync,
    );
    _ref.read(cartProvider.notifier).clear();
    _ref.invalidate(currentCashSessionProvider);
    _ref.invalidate(mySalesProvider);
    return outcome;
  }

  Future<Sale> invoice(String saleId) async {
    final sale = await _api.issueInvoice(saleId);
    _ref.invalidate(mySalesProvider);
    return sale;
  }

  /// Télécharge le PDF de la vente et l'envoie à l'impression / au partage.
  Future<void> printDocument(Sale sale) async {
    final bytes = await _api.saleDocument(sale.id);
    await _ref.read(printPdfProvider)(
      bytes,
      '${sale.invoiceNumber ?? sale.number}.pdf',
    );
  }

  Future<Customer> createCustomer(String name, String? phone) async {
    final customer = await _api.createCustomer(name: name, phone: phone);
    _ref.invalidate(customerSearchProvider);
    return customer;
  }

  /// Clé d'idempotence gardée par intention (`core/mutation_keys.dart`) : un
  /// nouvel essai après coupure ou délai dépassé
  /// réutilise le même id et le serveur n'efface pas la dette deux fois.
  Future<void> payCustomer(String customerId, int amount) async {
    await runMoneyMutation(
      _ref,
      'customer-payment:$customerId',
      (key) => _api.payCustomer(
        clientMutationId: key,
        customerId: customerId,
        amount: amount,
      ),
    );
    _ref.invalidate(customerSearchProvider);
    _ref.invalidate(currentCashSessionProvider);
  }
}

extension CustomerPaymentsActions on SalesActions {
  Future<List<PaymentHistoryItem>> customerPayments(String customerId) async =>
      (await _api.customerPayments(customerId)).data;

  /// Contre-passation (ADMIN) : écriture opposée, espèces rendues par la caisse.
  Future<void> reverseCustomerPayment(String paymentId, String reason) async {
    await runMoneyMutation(
      _ref,
      'reverse:customer-payment:$paymentId',
      (key) => _api.reverseCustomerPayment(
        paymentId,
        clientMutationId: key,
        reason: reason,
      ),
    );
    _ref.invalidate(customerSearchProvider);
    _ref.invalidate(currentCashSessionProvider);
  }
}

final salesActionsProvider = Provider<SalesActions>(SalesActions.new);
