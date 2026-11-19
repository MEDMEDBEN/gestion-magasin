import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/offline_write.dart';
import '../../../core/providers.dart';
import '../../../core/quantity.dart';
import '../../catalog/application/catalog_controller.dart';
import '../../catalog/data/catalog_models.dart';
import '../data/purchases_api.dart';
import '../../stock/application/stock_controller.dart';
import '../../suppliers/application/suppliers_controller.dart';

/// Une ligne du PANIER D'ACHAT (2026-11-19) : une colonne par lieu — ce qui
/// va au magasin, au dépôt, et « à répartir » (posé au dépôt, repère dans
/// Stock). Les trois se cumulent ; au moins une > 0 pour valider.
class PurchaseCartLine {
  PurchaseCartLine({
    required this.product,
    required this.unitPriceHt,
    Quantity? store,
    Quantity? depot,
    Quantity? split,
  }) : store = store ?? _zero,
       depot = depot ?? _zero,
       split = split ?? _zero;

  static final _zero = Quantity.zero;

  final Product product;

  /// Prix d'achat unitaire HT, centimes (> 0 pour valider).
  final int unitPriceHt;
  final Quantity store;
  final Quantity depot;
  final Quantity split;

  Quantity get total => store + depot + split;

  int get amount =>
      (total * Quantity.fromInt(unitPriceHt)).round().toBigInt().toInt();

  PurchaseCartLine copyWith({
    int? unitPriceHt,
    Quantity? store,
    Quantity? depot,
    Quantity? split,
  }) => PurchaseCartLine(
    product: product,
    unitPriceHt: unitPriceHt ?? this.unitPriceHt,
    store: store ?? this.store,
    depot: depot ?? this.depot,
    split: split ?? this.split,
  );

  /// Corps de la ligne pour `POST /purchases/direct`.
  Map<String, Object?> toJson() => {
    'productId': product.id,
    'unitPriceHt': unitPriceHt,
    if (store > Quantity.zero) 'toStore': quantityToJson(store),
    if (depot > Quantity.zero) 'toDepot': quantityToJson(depot),
    if (split > Quantity.zero) 'toSplit': quantityToJson(split),
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
  final List<PurchaseCartLine> lines;

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

  /// Ajoute un produit (une ligne par produit : un second ajout la remplace).
  void add(
    Product product, {
    int? unitPriceHt,
    Quantity? store,
    Quantity? depot,
    Quantity? split,
  }) {
    final line = PurchaseCartLine(
      product: product,
      unitPriceHt: unitPriceHt ?? product.lastPurchasePriceHt ?? 0,
      store: store,
      depot: depot,
      split: split,
    );
    state = PurchaseCart(
      id: state.id,
      supplierId: state.supplierId,
      supplierName: state.supplierName,
      // Le dernier ajouté EN TÊTE : il est sous les yeux, sous la barre d'ajout.
      lines: [
        line,
        for (final l in state.lines)
          if (l.product.id != product.id) l,
      ],
    );
  }

  void update(int index, PurchaseCartLine line) => state = PurchaseCart(
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
  // Le serveur a changé ces produits (prix d'achat, « prix à revoir »,
  // « à répartir ») : le catalogue local les relit TOUT DE SUITE.
  if (outcome is Applied<List<String>>) {
    await ref
        .read(catalogActionsProvider)
        .refreshProducts(cart.lines.map((l) => l.product.id));
  }
  if (clearCart) ref.read(purchaseCartProvider.notifier).clear();
  ref.invalidate(stockByProductProvider);
  ref.invalidate(soldByProductProvider);
  ref.invalidate(supplierSearchProvider);
  return outcome;
}
