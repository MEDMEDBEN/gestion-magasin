import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/dates.dart';
import '../../../core/error/api_exception.dart';
import '../../../core/error/error_codes.dart';
import '../../../core/mutation_keys.dart';
import '../../../core/providers.dart';
import '../../../core/quantity.dart';
import '../../catalog/data/catalog_api.dart';
import '../../catalog/data/catalog_repository.dart';
import '../../sales/application/sales_controller.dart';
import '../../sales/data/sales_api.dart';
import '../../sales/data/sales_models.dart';
import '../data/quote_models.dart';
import '../data/quotes_api.dart';

/// Filtre de statut de la liste (`null` = tous).
class QuoteFilter extends Notifier<QuoteStatus?> {
  @override
  QuoteStatus? build() => null;

  void set(QuoteStatus? status) => state = status;
}

final quoteFilterProvider = NotifierProvider<QuoteFilter, QuoteStatus?>(
  QuoteFilter.new,
);

/// Liste EN LIGNE : un devis périmé affiché comme valable enverrait convertir
/// un devis déjà converti ou expiré.
final quotesProvider = FutureProvider.autoDispose<List<Quote>>((ref) async {
  ref.watch(currentUserIdProvider);
  ref.watch(serverReachableProvider);
  final status = ref.watch(quoteFilterProvider);
  return (await ref.watch(quotesApiProvider).list(status: status)).data;
});

class QuoteActions {
  QuoteActions(this._ref);

  final Ref _ref;

  QuotesApi get _api => _ref.read(quotesApiProvider);

  void _refresh() => _ref.invalidate(quotesProvider);

  /// Devis du panier en cours — même recherche, même douchette, même prix
  /// modifié que la vente. Le panier est vidé une fois le devis enregistré :
  /// un devis ne sort RIEN du stock.
  Future<Quote> createFromCart({DateTime? validUntil}) async {
    final cart = _ref.read(cartProvider);
    // L'id du devis est la clé de l'intention « faire un devis de CE panier » :
    // un renvoi après coupure ne crée pas un second devis (le serveur répond
    // « existe déjà »).
    final quote = await runMoneyMutation(
      _ref,
      'quote:${cart.saleId}',
      (id) => _api.create(
        id: id,
        customerId: cart.customer?.id,
        validUntil: validUntil == null ? null : isoDay(validUntil),
        lines: _cartLines(cart),
      ),
    );
    _ref.read(cartProvider.notifier).clear();
    _refresh();
    return quote;
  }

  static List<QuoteLineInput> _cartLines(CartState cart) => [
    for (final line in cart.lines)
      (
        productId: line.product.id,
        quantity: quantityToJson(line.quantity),
        unitPriceHt: line.unitPriceHt,
        discountAmount: line.discountHt,
      ),
  ];

  /// Devis BROUILLON → panier de l'écran Vente (P1 bis n°21m) : même
  /// recherche, mêmes prix, mêmes remises que pour le faire. Un prix de ligne
  /// différent du tarif du client reste « modifié ».
  Future<void> editInCart(Quote quote) async {
    final products = {
      for (final p
          in await _ref.read(catalogRepositoryProvider).watchProducts().first)
        p.id: p,
    };
    Customer? customer;
    if (quote.customerId != null) {
      // ponytail: retrouvé par son nom (50 résultats), faute de lecture par
      // id côté vendeur ; plus de 50 homonymes → « introuvable ». Ajouter
      // `GET /customers/:id` à l'API de vente si cela arrive.
      final page = await _ref
          .read(salesApiProvider)
          .customers(query: quote.customerName);
      customer = page.data.where((c) => c.id == quote.customerId).firstOrNull;
      if (customer == null) throw _cannotEdit('son client est introuvable');
    }
    final tiers = await _ref.read(catalogApiProvider).priceTiers();
    final tierId =
        customer?.priceTierId ??
        tiers.where((t) => t.isDefault).firstOrNull?.id;
    final lines = <CartLine>[];
    for (final line in quote.lines) {
      final product = products[line.productId];
      if (product == null) {
        throw _cannotEdit('un de ses produits n’est plus au catalogue');
      }
      final tariff = product.prices
          .where((p) => p.priceTierId == tierId)
          .firstOrNull
          ?.priceHt;
      lines.add(
        CartLine(
          product,
          parseQuantity(line.quantity)!,
          unitPriceHt: line.unitPriceHt == tariff ? null : line.unitPriceHt,
          discountHt: line.discountAmount,
        ),
      );
    }
    _ref
        .read(cartProvider.notifier)
        .loadQuote((id: quote.id, number: quote.number), lines, customer);
  }

  /// Le panier remplace les lignes du devis en cours de modification ; le
  /// serveur chiffre avec les règles de la vente (tarif du client, ou prix
  /// promis gardé comme prix modifié ; plancher ; remise de l'admin reprise).
  Future<Quote> updateFromCart() async {
    final cart = _ref.read(cartProvider);
    final quote = await _api.update(
      cart.quote!.id,
      customerId: cart.customer?.id,
      lines: _cartLines(cart),
    );
    _ref.read(cartProvider.notifier).clear();
    _refresh();
    return quote;
  }

  static ApiException _cannotEdit(String why) => ApiException(
    statusCode: 422,
    code: ErrorCodes.validationFailed,
    message: 'Ce devis ne se modifie pas ici : $why.',
  );

  Future<Quote> send(Quote quote) => _then(_api.send(quote.id));
  Future<Quote> accept(Quote quote) => _then(_api.accept(quote.id));
  Future<Quote> refuse(Quote quote) => _then(_api.refuse(quote.id));

  Future<Quote> _then(Future<Quote> call) async {
    final quote = await call;
    _refresh();
    return quote;
  }

  /// Devis accepté → vente, par le MÊME cœur serveur que l'encaissement.
  /// Espèces : caisse ouverte obligatoire ; reste à crédit : client et échéance.
  Future<Sale> convert(
    Quote quote, {
    required int paidAmount,
    DateTime? dueDate,
  }) async {
    // ATTENDRE l'état de la caisse : lu pendant son chargement, il vaudrait
    // « pas de caisse » et refuserait une conversion parfaitement valable.
    final cash = paidAmount > 0
        ? await _ref.read(currentCashSessionProvider.future)
        : null;
    if (paidAmount > 0 && cash == null) {
      throw const ApiException(
        statusCode: 409,
        code: ErrorCodes.cashSessionRequired,
        message: 'Ouvrez la caisse avant d’encaisser des espèces',
      );
    }
    final sale = await runMoneyMutation(
      _ref,
      'quote-convert:${quote.id}',
      (key) => _api.convert(
        quote.id,
        clientMutationId: key,
        paidAmount: paidAmount,
        expectedTotalTtc: quote.totalTtc,
        cashSessionId: cash?.id,
        dueDate: dueDate == null ? null : isoDay(dueDate),
      ),
    );
    _refresh();
    _ref.invalidate(currentCashSessionProvider);
    _ref.invalidate(mySalesProvider);
    return sale;
  }

  /// PDF rendu serveur, vers l'impression / le partage (même chemin que le
  /// ticket et la facture).
  Future<void> print(Quote quote) async {
    final bytes = await _api.document(quote.id);
    await _ref.read(printPdfProvider)(bytes, '${quote.number}.pdf');
  }
}

final quoteActionsProvider = Provider<QuoteActions>(QuoteActions.new);
