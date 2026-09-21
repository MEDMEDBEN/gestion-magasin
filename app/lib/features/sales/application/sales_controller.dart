import 'package:decimal/decimal.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:printing/printing.dart';

import '../../../core/dates.dart';
import '../../../core/mutation_keys.dart';
import '../../../core/providers.dart';
import '../../../core/quantity.dart';
import '../../catalog/application/catalog_controller.dart';
import '../../catalog/data/catalog_models.dart';
import '../../payments/data/payment_models.dart';
import '../data/sales_api.dart';
import '../data/sales_models.dart';

/// Caisse ouverte du compte connecté (`null` : aucune). Lue en ligne.
final currentCashSessionProvider = FutureProvider.autoDispose<CashSession?>((
  ref,
) {
  ref.watch(currentUserIdProvider);
  return ref.watch(salesApiProvider).currentCashSession();
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

  Future<CashSession> openCash(String storeId, int openingFloat) async {
    final session = await runMoneyMutation(
      _ref,
      'cash-open',
      (key) => _api.openCashSession(
        clientMutationId: key,
        locationId: storeId,
        openingFloat: openingFloat,
      ),
    );
    _ref.invalidate(currentCashSessionProvider);
    return session;
  }

  Future<CashSession> closeCash(String sessionId, int countedAmount) async {
    final report = await runMoneyMutation(
      _ref,
      'cash-close:$sessionId',
      (key) => _api.closeCashSession(
        sessionId,
        clientMutationId: key,
        countedAmount: countedAmount,
      ),
    );
    _ref.invalidate(currentCashSessionProvider);
    return report;
  }

  /// Valide le panier. `paidAmount` : espèces GARDÉES (≤ total) ; le reste
  /// part en crédit client. Le panier n'est vidé qu'après succès.
  /// `expectedTotalTtc` : le total annoncé au client ; le serveur refuse (409)
  /// s'il a changé, pour ne jamais encaisser ou rendre la monnaie sur un faux total.
  /// `dueDate` : échéance OBLIGATOIRE dès qu'une partie reste à crédit.
  Future<Sale> checkout(
    int paidAmount, {
    required int expectedTotalTtc,
    DateTime? dueDate,
  }) async {
    final cart = _ref.read(cartProvider);
    // L'intention « valider CE panier » garde sa clé jusqu'au succès.
    final sale = await runMoneyMutation(
      _ref,
      'sale:${cart.saleId}',
      (key) => _api.createSale(
        clientMutationId: key,
        customerId: cart.customer?.id,
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
    );
    _ref.read(cartProvider.notifier).clear();
    _ref.invalidate(currentCashSessionProvider);
    _ref.invalidate(mySalesProvider);
    return sale;
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
