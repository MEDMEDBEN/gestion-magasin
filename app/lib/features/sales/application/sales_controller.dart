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
import '../../stock/application/stock_controller.dart';
import '../../payments/data/payment_models.dart';
import '../data/confrere.dart';
import '../data/sales_api.dart';
import '../data/sales_models.dart';
import '../../../ui/widgets/period_filter.dart';

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
) async => todaysCash(await _cashSession(ref)));

/// Une caisse ne vit qu'UN jour (décision MEDMEDBEN du 2026-10-08) : celle
/// d'un jour passé est close (le serveur la clôture) — on rouvre avec le fond
/// du jour. Vrai aussi hors ligne, sur l'état mémorisé.
CashSession? todaysCash(CashSession? session, [DateTime? now]) {
  if (session == null) return null;
  final opened = session.openedAt.toLocal();
  final today = (now ?? DateTime.now()).toLocal();
  final sameDay =
      opened.year == today.year &&
      opened.month == today.month &&
      opened.day == today.day;
  return sameDay ? session : null;
}

Future<CashSession?> _cashSession(Ref ref) async {
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
}

final customerSearchProvider = FutureProvider.autoDispose
    .family<List<Customer>, String>((ref, query) async {
      ref.watch(currentUserIdProvider);
      final page = await ref
          .watch(salesApiProvider)
          .customers(query: query.isEmpty ? null : query);
      return page.data;
    });

/// Confrères et soldes — lus EN LIGNE (les soldes sont calculés serveur).
final confreresProvider = FutureProvider.autoDispose<List<Confrere>>((ref) {
  ref.watch(currentUserIdProvider);
  return ref.watch(salesApiProvider).confreres();
});

final mySalesProvider = FutureProvider.autoDispose<List<Sale>>((ref) async {
  ref.watch(currentUserIdProvider);
  return (await ref.watch(salesApiProvider).sales()).data;
});

/// Filtre de l'historique : recherche et nombre de jours (null : tout).
typedef SalesHistoryFilter = ({String q, HistoryPeriod period});

/// Historique des ventes (spec §8) : les 200 plus récentes du filtre. Lu EN
/// LIGNE — une vente en file n'est pas encore définitive (règle 8).
final salesHistoryProvider = FutureProvider.autoDispose
    .family<SalePage, SalesHistoryFilter>((ref, filter) async {
      ref.watch(currentUserIdProvider);
      return ref
          .watch(salesApiProvider)
          .sales(
            limit: 200,
            q: filter.q.trim().isEmpty ? null : filter.q.trim(),
            from: filter.period.from,
            to: filter.period.to,
          );
    });

@immutable
class CartLine {
  const CartLine(
    this.product,
    this.quantity, {
    this.unitPriceHt,
    this.discountHt = 0,
  });

  final Product product;
  final Quantity quantity;

  /// Prix unitaire HT saisi par le vendeur (centimes) ; `null` = prix du tarif.
  final int? unitPriceHt;

  /// Remise HT sur la LIGNE, en centimes (ADMIN, `sale.discount`). Jamais au
  /// point de vendre sous le coût : vérifié ici ET par le serveur.
  final int discountHt;

  CartLine copyWith({Quantity? quantity, int? unitPriceHt, int? discountHt}) =>
      CartLine(
        product,
        quantity ?? this.quantity,
        unitPriceHt: unitPriceHt ?? this.unitPriceHt,
        discountHt: discountHt ?? this.discountHt,
      );
}

/// Montant HT brut d'une ligne (prix × quantité, arrondi au centime) — la
/// MÊME règle que le serveur, avant remise.
int lineGrossHt(int unitPriceHt, Quantity quantity) =>
    _roundMoney(Decimal.fromInt(unitPriceHt) * quantity);

/// Remise HT maximale d'une ligne, MÊME borne que le serveur : le net ne
/// descend jamais sous plancher × quantité (donc jamais sous 0). Sans
/// plancher connu, aucune remise.
int maxLineDiscountHt(Product product, int unitPriceHt, Quantity quantity) {
  final floor = priceFloor(product);
  if (floor == null) return 0;
  final max = lineGrossHt(unitPriceHt, quantity) - lineGrossHt(floor, quantity);
  return max < 0 ? 0 : max;
}

/// Plancher du prix de vente (décision 2026-09-22, MÊME règle que le serveur) :
/// le dernier prix d'achat ; sans coût connu (ou reçu gratuit), le plus bas des
/// tarifs du produit. `null` : aucune référence — le prix ne se fixe pas en
/// caisse, l'admin doit le définir.
int? priceFloor(Product product) {
  final cost = product.lastPurchasePriceHt;
  if (cost != null && cost > 0) return cost;
  final tariffs = product.prices.map((p) => p.priceHt);
  return tariffs.isEmpty ? null : tariffs.reduce((a, b) => a < b ? a : b);
}

/// Panier en cours. Il vit côté client jusqu'à la validation (pas de brouillon
/// serveur, docs/plan.md). `saleId` est généré avec le panier : un renvoi après
/// coupure réutilise le même id et le serveur ne crée pas de seconde vente.
@immutable
class CartState {
  const CartState({
    required this.saleId,
    this.lines = const [],
    this.customer,
    this.quote,
  });

  final String saleId;
  final List<CartLine> lines;
  final Customer? customer;

  /// Devis BROUILLON en cours de modification (P1 bis n°21m) : le panier le
  /// met à jour au lieu d'encaisser ou d'en créer un nouveau.
  final ({String id, String number})? quote;

  bool get isEmpty => lines.isEmpty;

  CartState copyWith({
    List<CartLine>? lines,
    ValueGetter<Customer?>? customer,
  }) => CartState(
    saleId: saleId,
    lines: lines ?? this.lines,
    customer: customer != null ? customer() : this.customer,
    quote: quote,
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
      lines[index] = lines[index].copyWith(
        quantity: lines[index].quantity + added,
      );
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
            line.copyWith(quantity: quantity),
      ],
    );
  }

  /// Prix unitaire HT modifié sur une ligne (le plancher est vérifié par l'écran
  /// ET par le serveur, qui fait foi).
  void setPrice(String productId, int unitPriceHt) {
    state = state.copyWith(
      lines: [
        for (final line in state.lines)
          line.product.id == productId
              ? line.copyWith(unitPriceHt: unitPriceHt)
              : line,
      ],
    );
  }

  /// Remise HT d'une ligne (0 : retirée).
  void setDiscount(String productId, int discountHt) {
    state = state.copyWith(
      lines: [
        for (final line in state.lines)
          line.product.id == productId
              ? line.copyWith(discountHt: discountHt)
              : line,
      ],
    );
  }

  void setCustomer(Customer? customer) =>
      state = state.copyWith(customer: () => customer);

  /// Nouveau panier, nouvel identifiant de vente.
  void clear() => state = CartState(saleId: ref.read(uuidProvider).v7());

  /// Panier rempli par un devis BROUILLON à modifier (remplace le panier).
  void loadQuote(
    ({String id, String number}) quote,
    List<CartLine> lines,
    Customer? customer,
  ) => state = CartState(
    saleId: ref.read(uuidProvider).v7(),
    lines: lines,
    customer: customer,
    quote: quote,
  );
}

final cartProvider = NotifierProvider<CartController, CartState>(
  CartController.new,
);

/// Estimation affichée pendant la saisie, avec les MÊMES règles que le serveur
/// (prix du tarif du client ou par défaut, arrondi au centime demi-haut ; sans
/// TVA depuis le 2026-10-05 : le total est la somme des lignes).
/// Le serveur recalcule et fait foi : cette valeur n'est jamais envoyée.
@immutable
class CartEstimate {
  const CartEstimate({
    required this.totalHt,
    required this.missingPrices,
    this.invalidDiscounts = const [],
    this.lineTotalsHt = const {},
    this.unitPricesHt = const {},
    this.tariffPricesHt = const {},
  });

  final int totalHt;

  /// Sans TVA, le total payé est le total des lignes.
  int get totalTtc => totalHt;

  /// Produits sans prix pour le tarif applicable : la vente serait refusée.
  final List<Product> missingPrices;

  /// Remise devenue trop forte (quantité, prix ou client changés après coup) :
  /// le serveur refuserait — hors ligne, APRÈS le départ du client.
  final List<Product> invalidDiscounts;

  /// Encaissement ou devis impossible tant qu'une ligne est dans ce cas.
  bool get blocked => missingPrices.isNotEmpty || invalidDiscounts.isNotEmpty;

  /// Total HT estimé par produit (affiché sur chaque ligne du panier).
  final Map<String, int> lineTotalsHt;

  /// Prix unitaire HT APPLIQUÉ par produit (saisi, sinon tarif) — c'est lui qui
  /// part au serveur : le prix vu par le client fait foi, même hors ligne.
  final Map<String, int> unitPricesHt;

  /// Prix du tarif par produit (absent : pas de tarif pour ce produit).
  final Map<String, int> tariffPricesHt;
}

int _roundMoney(Decimal value) =>
    value.round(scale: 0).toBigInt().toInt(); // demi vers le haut (positif)

CartEstimate estimateCart(
  CartState cart, {
  required String? defaultTierId,
  Set<String>? activeTierIds,
}) {
  // MÊME règle que le serveur (`priceCart`) : le tarif du client s'il est
  // encore ACTIF, sinon le tarif par défaut. Liste des tarifs inconnue (hors
  // ligne) : celui du client — le serveur tranche à la synchro.
  final customerTier = cart.customer?.priceTierId;
  final tierId =
      customerTier != null &&
          (activeTierIds == null || activeTierIds.contains(customerTier))
      ? customerTier
      : defaultTierId;
  var ht = 0;
  final missing = <Product>[];
  final invalid = <Product>[];
  final lineTotals = <String, int>{};
  final unitPrices = <String, int>{};
  final tariffs = <String, int>{};
  for (final line in cart.lines) {
    final tariff = line.product.prices
        .where((p) => p.priceTierId == tierId)
        .firstOrNull
        ?.priceHt;
    if (tariff != null) tariffs[line.product.id] = tariff;
    final price = line.unitPriceHt ?? tariff;
    if (price == null) {
      missing.add(line.product);
      continue;
    }
    unitPrices[line.product.id] = price;
    if (line.discountHt >
        maxLineDiscountHt(line.product, price, line.quantity)) {
      invalid.add(line.product);
    }
    final lineHt = lineGrossHt(price, line.quantity) - line.discountHt;
    lineTotals[line.product.id] = lineHt;
    ht += lineHt;
  }
  return CartEstimate(
    totalHt: ht,
    missingPrices: missing,
    invalidDiscounts: invalid,
    lineTotalsHt: lineTotals,
    unitPricesHt: unitPrices,
    tariffPricesHt: tariffs,
  );
}

final cartEstimateProvider = Provider.autoDispose<CartEstimate>((ref) {
  final tiers = ref.watch(priceTiersProvider).value ?? const <PriceTier>[];
  return estimateCart(
    ref.watch(cartProvider),
    defaultTierId: tiers.where((t) => t.isDefault).firstOrNull?.id,
    activeTierIds: tiers.isEmpty ? null : {for (final t in tiers) t.id},
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

  /// Mouvement MANUEL de caisse (P1 bis n°21k) : `ENTREE`, `SORTIE` ou
  /// `PRELEVEMENT`, avec motif. Mutation d'argent : la clé de l'intention
  /// survit aux nouveaux essais (jamais deux sorties). En ligne seulement.
  Future<CashSession> cashMovement(
    String sessionId, {
    required String type,
    required int amount,
    required String note,
  }) async {
    // Intention = CETTE caisse, CE type : ni montant ni motif, ressaisis
    // (autrement) au nouvel essai après une coupure — une clé neuve ferait
    // sortir l'argent deux fois. Un montant différent : 409, l'utilisateur
    // vérifie ; le succès libère la clé (un 2e mouvement voulu en est un neuf).
    try {
      return await runMoneyMutation(
        _ref,
        'cash-move:$sessionId:$type',
        (key) => _api.cashMovement(sessionId, {
          'clientMutationId': key,
          'type': type,
          'amount': amount,
          'note': note,
        }),
      );
    } finally {
      // Succès ou refus (caisse clôturée, tiroir insuffisant) : la barre relit
      // l'état réel.
      _ref.invalidate(currentCashSessionProvider);
    }
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
  /// `expectedTotalTtc` : le total annoncé au client. En ligne, le serveur
  /// refuse (409) si un tarif a changé sur une ligne non modifiée (catalogue en
  /// retard) ; hors ligne, le prix affiché fait foi (sans TVA depuis le
  /// 2026-10-05) — jamais d'encaissement sur un faux total.
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
    // Prix APPLIQUÉ de chaque ligne, envoyé explicitement : si le tarif change
    // pendant une coupure, c'est le prix vu par le client qui est vendu.
    final unitPrices = _ref.read(cartEstimateProvider).unitPricesHt;
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
              unitPriceHt: unitPrices[line.product.id],
              // Prix saisi par le vendeur : tracé pour l'admin ; sinon c'est
              // le tarif affiché, que le serveur revérifie en ligne.
              priceEdited: line.unitPriceHt != null,
              discountAmount: line.discountHt,
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
    _ref.invalidate(salesHistoryProvider);
    return sale;
  }

  /// Retour client (ADMIN, P1 bis n°21l). Mutation d'argent : la clé de
  /// l'intention « rendre sur CETTE vente » survit aux nouveaux essais.
  Future<SaleReturn> returnItems(
    String saleId, {
    required Map<String, Quantity> quantities,
    required String refundMethod,
    required String reason,
  }) async {
    final id = _ref.read(uuidProvider).v7();
    try {
      return await runMoneyMutation(
        _ref,
        'sale-return:$saleId',
        (key) => _api.createReturn(saleId, {
          'id': id,
          'clientMutationId': key,
          'lines': [
            for (final e in quantities.entries)
              {'saleLineId': e.key, 'quantity': quantityToJson(e.value)},
          ],
          'refundMethod': refundMethod,
          'reason': reason,
        }),
      );
    } finally {
      _ref
        ..invalidate(salesHistoryProvider)
        ..invalidate(currentCashSessionProvider)
        ..invalidate(stockByProductProvider)
        ..invalidate(customerSearchProvider);
    }
  }

  /// Imprime la facture d'avoir / le bon de retour.
  Future<void> printReturn(SaleReturn ret) async {
    final bytes = await _api.returnDocument(ret.id);
    await _ref.read(printPdfProvider)(
      bytes,
      '${ret.creditNoteNumber ?? ret.number}.pdf',
    );
  }

  /// Annulation (ADMIN) : le stock revient, la caisse rend l'espèce.
  Future<Sale> cancel(String saleId) async {
    final sale = await _api.cancelSale(saleId);
    _ref.invalidate(salesHistoryProvider);
    _ref.invalidate(currentCashSessionProvider);
    _ref.invalidate(stockByProductProvider);
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

  Future<Customer> saveCustomer(String? id, Map<String, Object?> fields) async {
    final customer = await _api.saveCustomer(id, fields);
    _ref.invalidate(customerSearchProvider);
    return customer;
  }

  /// Clé d'idempotence gardée par intention (`core/mutation_keys.dart`) : un
  /// nouvel essai après coupure ou délai dépassé
  /// réutilise le même id et le serveur n'efface pas la dette deux fois.
  ///
  /// Sans réseau, le règlement part dans la file : il porte la caisse où les
  /// espèces sont entrées (comme la vente) et le serveur le rejuge au sync (dette
  /// peut-être déjà réglée entre-temps) — jamais présenté comme définitif.
  Future<WriteOutcome<void>> payCustomer(String customerId, int amount) async {
    final cash = _ref.read(currentCashSessionProvider).value;
    if (cash == null) {
      throw const ApiException(
        statusCode: 409,
        code: ErrorCodes.cashSessionRequired,
        message: 'Ouvrez la caisse avant d’encaisser un règlement',
      );
    }
    final outcome = await writeOnlineOrQueue<void>(
      _ref,
      intent: 'customer-payment:$customerId',
      operationType: 'CUSTOMER_PAYMENT',
      payload: (key) => {
        'clientMutationId': key,
        'id': key,
        'customerId': customerId,
        'amount': amount,
        'cashSessionId': cash.id,
      },
      online: _api.payCustomer,
      // Caisse encore en file : le règlement passe APRÈS son ouverture.
      queueOnly: cash.status == cashPendingSync,
    );
    _ref.invalidate(customerSearchProvider);
    _ref.invalidate(currentCashSessionProvider);
    return outcome;
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
