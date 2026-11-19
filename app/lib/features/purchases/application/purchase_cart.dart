import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/offline_write.dart';
import '../../../core/providers.dart';
import '../../../core/quantity.dart';
import '../../catalog/data/catalog_models.dart';
import '../data/purchases_api.dart';
import '../../stock/application/stock_controller.dart';
import '../../suppliers/application/suppliers_controller.dart';

/// Où va la marchandise achetée (demande MEDMEDBEN du 2026-11-19).
enum PurchaseDestination {
  store('Magasin'),
  depot('Dépôt'),
  both('Les deux'),
  split('En total (à répartir)');

  const PurchaseDestination(this.label);
  final String label;
}

/// Une ligne du PANIER D'ACHAT.
class PurchaseLine {
  PurchaseLine({
    required this.product,
    required this.unitPriceHt,
    this.destination = PurchaseDestination.depot,
    Quantity? quantity,
    Quantity? toStore,
    Quantity? toDepot,
  }) : quantity = quantity ?? _zero,
       toStore = toStore ?? _zero,
       toDepot = toDepot ?? _zero;

  static final _zero = Quantity.zero;

  final Product product;

  /// Prix d'achat unitaire HT, centimes (≥ 0).
  final int unitPriceHt;
  final PurchaseDestination destination;

  /// Quantité unique (magasin, dépôt ou en total).
  final Quantity quantity;

  /// « Les deux » : la part de chaque lieu.
  final Quantity toStore;
  final Quantity toDepot;

  Quantity get total =>
      destination == PurchaseDestination.both ? toStore + toDepot : quantity;

  int get amount =>
      (total * Quantity.fromInt(unitPriceHt)).round().toBigInt().toInt();

  PurchaseLine copyWith({
    int? unitPriceHt,
    PurchaseDestination? destination,
    Quantity? quantity,
    Quantity? toStore,
    Quantity? toDepot,
  }) => PurchaseLine(
    product: product,
    unitPriceHt: unitPriceHt ?? this.unitPriceHt,
    destination: destination ?? this.destination,
    quantity: quantity ?? this.quantity,
    toStore: toStore ?? this.toStore,
    toDepot: toDepot ?? this.toDepot,
  );

  /// Corps de la ligne pour `POST /purchases/direct`.
  Map<String, Object?> toJson() => {
    'productId': product.id,
    'unitPriceHt': unitPriceHt,
    ...switch (destination) {
      PurchaseDestination.store => {'toStore': quantityToJson(quantity)},
      PurchaseDestination.depot => {'toDepot': quantityToJson(quantity)},
      PurchaseDestination.split => {'toSplit': quantityToJson(quantity)},
      PurchaseDestination.both => {
        'toStore': quantityToJson(toStore),
        'toDepot': quantityToJson(toDepot),
      },
    },
  };
}

/// Brouillon d'achat : il VIT pendant la session (on peut quitter l'écran,
/// créer un produit ailleurs, revenir) ; vidé à la validation.
class PurchaseCart {
  const PurchaseCart({
    required this.id,
    this.supplierId,
    this.supplierName,
    this.lines = const [],
  });

  /// Clé de l'intention « valider CE panier » (même clé à chaque essai).
  final String id;
  final String? supplierId;
  final String? supplierName;
  final List<PurchaseLine> lines;

  int get total => lines.fold(0, (sum, l) => sum + l.amount);
  bool get isEmpty => lines.isEmpty;
}

class PurchaseCartNotifier extends Notifier<PurchaseCart> {
  @override
  PurchaseCart build() {
    ref.watch(currentUserIdProvider);
    return PurchaseCart(id: ref.read(uuidProvider).v7());
  }

  void setSupplier(String? id, String? name) => state = PurchaseCart(
    id: state.id,
    supplierId: id,
    supplierName: name,
    lines: state.lines,
  );

  /// Ajoute un produit (ou augmente sa ligne si elle existe déjà).
  void add(
    Product product, {
    int? unitPriceHt,
    PurchaseDestination destination = PurchaseDestination.depot,
    Quantity? quantity,
    Quantity? toStore,
    Quantity? toDepot,
  }) {
    final line = PurchaseLine(
      product: product,
      unitPriceHt: unitPriceHt ?? product.lastPurchasePriceHt ?? 0,
      destination: destination,
      quantity: quantity,
      toStore: toStore,
      toDepot: toDepot,
    );
    state = PurchaseCart(
      id: state.id,
      supplierId: state.supplierId,
      supplierName: state.supplierName,
      lines: [
        for (final l in state.lines)
          if (l.product.id != product.id) l,
        line,
      ],
    );
  }

  void update(int index, PurchaseLine line) => state = PurchaseCart(
    id: state.id,
    supplierId: state.supplierId,
    supplierName: state.supplierName,
    lines: [for (final (i, l) in state.lines.indexed) i == index ? line : l],
  );

  void remove(int index) => state = PurchaseCart(
    id: state.id,
    supplierId: state.supplierId,
    supplierName: state.supplierName,
    lines: [
      for (final (i, l) in state.lines.indexed)
        if (i != index) l,
    ],
  );

  void clear() => state = PurchaseCart(id: ref.read(uuidProvider).v7());
}

final purchaseCartProvider =
    NotifierProvider<PurchaseCartNotifier, PurchaseCart>(
      PurchaseCartNotifier.new,
    );

/// Envoi d'un achat, depuis un écran (`ref.read(purchaseSubmitProvider)`).
final purchaseSubmitProvider = Provider(
  (ref) =>
      ({
        required PurchaseCart cart,
        int paidAmount = 0,
        bool clearCart = true,
      }) => submitPurchase(
        ref,
        cart: cart,
        paidAmount: paidAmount,
        clearCart: clearCart,
      ),
);

/// L'achat validé (en ligne) ou mis en file (hors ligne) : le stock entre,
/// le reste non payé va en dette du fournisseur.
Future<WriteOutcome<List<String>>> submitPurchase(
  Ref ref, {
  required PurchaseCart cart,
  int paidAmount = 0,
  bool clearCart = true,
}) async {
  final outcome = await writeOnlineOrQueue<List<String>>(
    ref,
    intent: 'purchase:${cart.id}',
    operationType: 'PURCHASE_ORDER',
    payload: (key) => {
      'clientMutationId': key,
      'supplierId': cart.supplierId,
      'lines': [for (final l in cart.lines) l.toJson()],
      if (paidAmount > 0) 'paidAmount': paidAmount,
    },
    online: ref.read(purchasesApiProvider).directPurchase,
  );
  if (clearCart) ref.read(purchaseCartProvider.notifier).clear();
  ref.invalidate(stockByProductProvider);
  ref.invalidate(supplierSearchProvider);
  return outcome;
}
