import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/error/api_exception.dart';
import '../../../core/money.dart';
import '../../../core/quantity.dart';
import '../../../ui/breakpoints.dart';
import '../../../ui/navigation.dart';
import '../../../ui/theme/ampere_colors.dart';
import '../../../ui/theme/ampere_typography.dart';
import '../../../ui/widgets/ampere_controls.dart';
import '../../../ui/widgets/screen_state.dart';
import '../../catalog/data/catalog_models.dart' show productUnitShort;
import '../application/replenishment_controller.dart';
import '../data/replenishment_api.dart';
import '../data/replenishment_models.dart';

/// Réapprovisionnement (spec §19) : ce qu'il faut racheter, du plus urgent au
/// moins urgent.
///
/// L'écran ne commande RIEN. Il propose une quantité que l'utilisateur ajuste,
/// puis il faut passer par la commande fournisseur (écran Achats) : la
/// préparation automatique de la commande est remise à P2 (n°22), et une
/// commande créée d'un clic depuis une suggestion serait une commande que
/// personne n'a relue.
class ReplenishmentScreen extends ConsumerStatefulWidget {
  const ReplenishmentScreen({super.key});

  @override
  ConsumerState<ReplenishmentScreen> createState() =>
      _ReplenishmentScreenState();
}

class _ReplenishmentScreenState extends ConsumerState<ReplenishmentScreen> {
  bool _outOfStockOnly = false;

  /// Quantités ajustées par l'utilisateur, par produit. Vivent le temps de
  /// l'écran : rien n'est envoyé au serveur tant qu'aucune commande n'est créée.
  final _adjusted = <String, Quantity>{};

  ReplenishmentFilter get _filter => (outOfStockOnly: _outOfStockOnly);

  bool _preparing = false;

  /// P2 n°22 : les lignes affichées (quantités ajustées comprises) deviennent
  /// des commandes BROUILLON, une par fournisseur principal ; on les vérifie
  /// ensuite dans Achats, où l'admin les confirme.
  Future<void> _prepare(List<ReplenishmentLine> lines, int total) async {
    // Quantité AFFICHÉE ; une ligne à 0 (ou vidée) est écartée.
    final toSend = [
      for (final l in lines)
        (
          productId: l.productId,
          quantity:
              _adjusted[l.productId] ?? quantityFromJson(l.suggestedQuantity),
        ),
    ].where((l) => l.quantity > Quantity.zero).toList();
    if (toSend.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Aucune quantité à commander.')),
      );
      return;
    }
    final skipped = lines.length - toSend.length;
    final sure = await showAmpereConfirmDialog(
      context,
      title: 'Préparer les commandes ?',
      body:
          '${toSend.length} produit(s) affiché(s)'
          '${total > lines.length ? ' (sur $total à racheter : les autres ne sont pas affichés)' : ''}'
          '${skipped > 0 ? ', $skipped écarté(s) à 0' : ''} → une commande '
          'BROUILLON par fournisseur principal, au dernier prix d’achat. Rien '
          'n’est envoyé ni confirmé.',
      confirmLabel: 'Préparer',
    );
    if (!sure || !mounted) return;
    setState(() => _preparing = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final result = await ref.read(replenishmentApiProvider).prepareOrders([
        for (final l in toSend)
          (productId: l.productId, quantity: quantityToJson(l.quantity)),
      ]);
      final orders = result['orders'] as List<dynamic>;
      final missing = (result['withoutSupplier'] as List<dynamic>)
          .cast<String>();
      final unpriced = result['unpricedLines'] as int? ?? 0;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            '${orders.length} commande(s) préparée(s) — à vérifier dans Achats'
            '${unpriced == 0 ? '' : ' · $unpriced ligne(s) sans prix d’achat connu (0) : à compléter'}'
            '${missing.isEmpty ? '' : ' · sans fournisseur principal : ${missing.join(', ')}'}',
          ),
        ),
      );
      if (orders.isNotEmpty && mounted) goToDestination(ref, 'Achats');
    } on ApiException catch (error) {
      // Des brouillons ont pu être créés pour d'autres fournisseurs.
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            '${error.userMessage} — vérifiez les brouillons dans Achats.',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _preparing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    final margin = isDesktopWidth(MediaQuery.sizeOf(context).width)
        ? 24.0
        : 16.0;
    final page = ref.watch(replenishmentProvider(_filter));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(margin, 14, margin, 10),
          // Wrap : sur mobile, le bouton passe à la ligne au lieu de déborder.
          child: Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilterChip(
                label: const Text('Ruptures seulement'),
                selected: _outOfStockOnly,
                onSelected: (on) => setState(() => _outOfStockOnly = on),
              ),
              if (page.value case final data? when data.data.isNotEmpty)
                FilledButton.icon(
                  onPressed: _preparing
                      ? null
                      : () => _prepare(data.data, data.meta.total),
                  icon: const Icon(Icons.playlist_add_check, size: 18),
                  label: const Text('Préparer les commandes'),
                ),
              if (page.value case final data?)
                Text(
                  data.outOfStockCount == 0
                      ? '${data.meta.total} à racheter'
                      : '${data.meta.total} à racheter · '
                            '${data.outOfStockCount} en rupture',
                  style: AmpereType.meta.copyWith(color: colors.ink3),
                ),
            ],
          ),
        ),
        Expanded(
          child: page.when(
            loading: () => const AmpereSkeletonList(rows: 5),
            error: (error, _) => ScreenStateView(
              status: error is ApiException && error.isOffline
                  ? ScreenStatus.offline
                  : ScreenStatus.error,
              message: error is ApiException
                  ? error.userMessage
                  : 'La liste de réapprovisionnement n’a pas pu être chargée.',
              onRetry: () => ref.invalidate(replenishmentProvider(_filter)),
            ),
            data: (data) => data.data.isEmpty
                ? const ScreenStateView(
                    status: ScreenStatus.empty,
                    title: 'Rien à racheter',
                    message:
                        'Aucun produit n’est sous son seuil minimum. Le seuil '
                        'se règle sur la fiche produit — sans seuil, seules '
                        'les ruptures remontent ici.',
                  )
                : ListView(
                    padding: EdgeInsets.fromLTRB(margin, 0, margin, 24),
                    children: [
                      for (final line in data.data)
                        _ReplenishmentTile(
                          // CLÉ PAR PRODUIT, indispensable : la liste se
                          // rafraîchit au battement de synchro et son ORDRE
                          // dépend de l'urgence. Sans clé, Flutter réassocie
                          // l'état par POSITION — la quantité saisie sautait sur
                          // un AUTRE produit après un réordonnancement, pendant
                          // que le montant restait celui du bon. Une commande
                          // fausse et invisible (trouvé par la revue).
                          key: ValueKey(line.productId),
                          line: line,
                          adjusted: _adjusted[line.productId],
                          onAdjust: (quantity) => setState(() {
                            if (quantity == null) {
                              _adjusted.remove(line.productId);
                            } else {
                              _adjusted[line.productId] = quantity;
                            }
                          }),
                        ),
                    ],
                  ),
          ),
        ),
      ],
    );
  }
}

/// Coût estimé d'une quantité, en centimes. Arrondi à l'entier : c'est une
/// ESTIMATION d'écran, le montant qui engage est celui de la commande.
int estimatedCost(Quantity quantity, int unitPriceCentimes) =>
    (quantity * Decimal.fromInt(unitPriceCentimes)).round().toBigInt().toInt();

class _ReplenishmentTile extends StatelessWidget {
  const _ReplenishmentTile({
    super.key,
    required this.line,
    required this.adjusted,
    required this.onAdjust,
  });

  final ReplenishmentLine line;
  final Quantity? adjusted;
  final ValueChanged<Quantity?> onAdjust;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    final suggested = quantityFromJson(line.suggestedQuantity);
    final toOrder = adjusted ?? suggested;
    final unitCost = line.lastPurchasePriceHt;

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(line.name, style: AmpereType.rowTitle),
                      const SizedBox(height: 2),
                      Text(
                        [
                          line.sku,
                          'reste ${formatQuantity(quantityFromJson(line.quantity))} '
                              '${productUnitShort(line.unit)}',
                          if (quantityFromJson(line.minThreshold) >
                              Decimal.zero)
                            'seuil ${formatQuantity(quantityFromJson(line.minThreshold))}',
                          line.supplierName ?? 'sans fournisseur principal',
                        ].join(' · '),
                        style: AmpereType.meta.copyWith(color: colors.ink3),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                AmpereBadge(
                  label: line.isOutOfStock ? 'RUPTURE' : 'STOCK FAIBLE',
                  tone: line.isOutOfStock ? StatusTone.error : StatusTone.warn,
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                SizedBox(
                  width: 132,
                  child: _QuantityField(
                    initial: suggested,
                    onChanged: onAdjust,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    unitCost == null
                        // Sans coût connu, on n'invente pas un montant : la
                        // commande fournisseur demandera le prix.
                        ? 'Prix d’achat inconnu — à saisir à la commande'
                        // Le montant suit la quantité AFFICHÉE : le serveur n'en
                        // envoie pas de version précalculée, elle serait fausse
                        // dès la première frappe de l'utilisateur.
                        : '${formatDA(unitCost)} l’unité · environ '
                              '${formatDA(estimatedCost(toOrder, unitCost))}',
                    style: AmpereType.meta.copyWith(color: colors.ink3),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Quantité à commander, MODIFIABLE (spec §19 : « l'utilisateur peut modifier
/// avant de commander »). Le champ appartient au widget, qui le libère lui-même.
class _QuantityField extends StatefulWidget {
  const _QuantityField({required this.initial, required this.onChanged});

  final Quantity initial;
  final ValueChanged<Quantity?> onChanged;

  @override
  State<_QuantityField> createState() => _QuantityFieldState();
}

class _QuantityFieldState extends State<_QuantityField> {
  late final TextEditingController _controller = TextEditingController(
    text: formatQuantity(widget.initial),
  );

  /// Reprend la proposition du serveur quand elle change, MAIS seulement si
  /// l'utilisateur n'a rien saisi : sa frappe ne doit jamais être écrasée par un
  /// rafraîchissement. Sans ça, le champ gardait éternellement la première
  /// proposition alors que le montant affiché suivait la nouvelle — les deux se
  /// contredisaient (relevé par la revue).
  @override
  void didUpdateWidget(_QuantityField old) {
    super.didUpdateWidget(old);
    if (widget.initial != old.initial &&
        _controller.text == formatQuantity(old.initial)) {
      _controller.text = formatQuantity(widget.initial);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
      decoration: const InputDecoration(
        labelText: 'À commander',
        isDense: true,
        prefixIcon: Icon(LucideIcons.shoppingCart, size: 16),
      ),
      // Champ VIDÉ = 0 : la ligne est écartée de la préparation (P2 n°22),
      // jamais remplacée en silence par la proposition.
      onChanged: (text) => widget.onChanged(
        text.trim().isEmpty ? Quantity.zero : parseQuantity(text),
      ),
    );
  }
}
