import 'package:decimal/decimal.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../../../core/quantity.dart';
import '../../catalog/application/catalog_controller.dart';
import '../../catalog/data/catalog_models.dart';
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
  });

  final int totalHt;
  final int totalTax;
  int get totalTtc => totalHt + totalTax;

  /// Produits sans prix pour le tarif applicable : la vente serait refusée.
  final List<Product> missingPrices;
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
    ht += lineHt;
    tax += _roundMoney(
      (Decimal.fromInt(lineHt) * rate / Decimal.fromInt(100)).toDecimal(
        scaleOnInfinitePrecision: 6,
      ),
    );
  }
  return CartEstimate(totalHt: ht, totalTax: tax, missingPrices: missing);
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

/// Écritures Caisse / Ventes / Clients — toujours validées par le serveur.
class SalesActions {
  SalesActions(this._ref);

  final Ref _ref;

  SalesApi get _api => _ref.read(salesApiProvider);

  Future<CashSession> openCash(String storeId, int openingFloat) async {
    final session = await _api.openCashSession(
      locationId: storeId,
      openingFloat: openingFloat,
    );
    _ref.invalidate(currentCashSessionProvider);
    return session;
  }

  Future<CashSession> closeCash(String sessionId, int countedAmount) async {
    final report = await _api.closeCashSession(
      sessionId,
      countedAmount: countedAmount,
    );
    _ref.invalidate(currentCashSessionProvider);
    return report;
  }

  /// Valide le panier. `paidAmount` : espèces GARDÉES (≤ total) ; le reste
  /// part en crédit client. Le panier n'est vidé qu'après succès.
  Future<Sale> checkout(int paidAmount) async {
    final cart = _ref.read(cartProvider);
    final sale = await _api.createSale(
      id: cart.saleId,
      customerId: cart.customer?.id,
      lines: [
        for (final line in cart.lines)
          (productId: line.product.id, quantity: quantityToJson(line.quantity)),
      ],
      paidAmount: paidAmount,
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

  Future<Customer> createCustomer(String name, String? phone) async {
    final customer = await _api.createCustomer(name: name, phone: phone);
    _ref.invalidate(customerSearchProvider);
    return customer;
  }

  /// `paymentId` : généré UNE fois par saisie — un renvoi après coupure
  /// réutilise le même id et le serveur n'efface pas la dette deux fois.
  Future<void> payCustomer(
    String customerId,
    int amount, {
    required String paymentId,
  }) async {
    await _api.payCustomer(
      id: paymentId,
      customerId: customerId,
      amount: amount,
    );
    _ref.invalidate(customerSearchProvider);
    _ref.invalidate(currentCashSessionProvider);
  }
}

final salesActionsProvider = Provider<SalesActions>(SalesActions.new);
