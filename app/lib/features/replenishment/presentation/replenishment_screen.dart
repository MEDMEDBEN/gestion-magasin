import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/error/api_exception.dart';
import '../../../core/money.dart';
import '../../../core/quantity.dart';
import '../../../ui/breakpoints.dart';
import '../../../ui/theme/ampere_colors.dart';
import '../../../ui/theme/ampere_typography.dart';
import '../../../ui/widgets/screen_state.dart';
import '../../catalog/data/catalog_models.dart' show productUnitShort;
import '../application/replenishment_controller.dart';
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
          child: Row(
            children: [
              FilterChip(
                label: const Text('Ruptures seulement'),
                selected: _outOfStockOnly,
                onSelected: (on) => setState(() => _outOfStockOnly = on),
              ),
              const Spacer(),
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
      onChanged: (text) => widget.onChanged(parseQuantity(text)),
    );
  }
}
