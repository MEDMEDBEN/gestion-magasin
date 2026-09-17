import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/error/api_exception.dart';
import '../../../core/error/error_codes.dart';
import '../../../core/money.dart';
import '../../../core/quantity.dart';
import '../../../ui/breakpoints.dart';
import '../../../ui/theme/ampere_colors.dart';
import '../../../ui/theme/ampere_typography.dart';
import '../../../ui/widgets/screen_state.dart';
import '../../auth/data/auth_models.dart';
import '../../catalog/application/catalog_controller.dart';
import '../../catalog/data/catalog_models.dart';
import '../../catalog/data/catalog_repository.dart';
import '../application/sales_controller.dart';
import '../data/sales_models.dart';

/// Droits de la vente, MIROIRS des guards serveur (`docs/permissions.md`).
class SalesRights {
  SalesRights(AuthUser user)
    : canSell =
          (user.hasRole('ADMIN') || user.hasRole('VENDEUR')) &&
          user.can('sale.create'),
      canInvoice = user.can('invoice.issue'),
      canManageCash = user.can('cash.session.manage'),
      canWriteCustomers = user.can('customer.write'),
      canTakePayments = user.can('customer.payment.create');

  final bool canSell;
  final bool canInvoice;
  final bool canManageCash;
  final bool canWriteCustomers;
  final bool canTakePayments;
}

enum _Section { sale, customers }

void _snack(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        action: SnackBarAction(label: 'Fermer', onPressed: () {}),
      ),
    );
}

/// Relance automatique UNE fois si le serveur n'a pas répondu : l'opération
/// porte un id stable, un doublon est donc impossible côté serveur.
Future<T> _retryable<T>(Future<T> Function() action) async {
  try {
    return await action();
  } on ApiException catch (error) {
    if (!error.isOffline) rethrow;
    return action();
  }
}

String _errorText(Object error) =>
    error is ApiException ? error.userMessage : 'Action impossible';

/// Vente au comptoir : caisse, panier (recherche ou douchette), client,
/// encaissement espèces / crédit, ticket et facture. Tout est validé EN LIGNE
/// par le serveur (prix, stock, caisse, plafond) — la vente hors-ligne arrive
/// avec la feature P0 n°12.
class SalesScreen extends ConsumerStatefulWidget {
  const SalesScreen({super.key, required this.user});

  final AuthUser user;

  @override
  ConsumerState<SalesScreen> createState() => _SalesScreenState();
}

class _SalesScreenState extends ConsumerState<SalesScreen> {
  _Section _section = _Section.sale;

  @override
  void initState() {
    super.initState();
    // Entrée en Vente : prix et produits à jour avant d'encaisser.
    Future.microtask(() {
      if (mounted) ref.read(catalogSyncProvider.notifier).refresh();
    });
  }

  @override
  Widget build(BuildContext context) {
    final rights = SalesRights(widget.user);
    final isDesktop = isDesktopWidth(MediaQuery.sizeOf(context).width);
    final margin = isDesktop
        ? AmpereGeometry.screenMarginDesktop
        : AmpereGeometry.screenMarginMobile;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(margin, 14, margin, 0),
          child: Wrap(
            spacing: 12,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SegmentedButton<_Section>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: _Section.sale, label: Text('Vente')),
                  ButtonSegment(
                    value: _Section.customers,
                    label: Text('Clients'),
                  ),
                ],
                selected: {_section},
                onSelectionChanged: (s) => setState(() => _section = s.first),
              ),
              if (rights.canManageCash) const _CashBar(),
            ],
          ),
        ),
        Expanded(
          child: _section == _Section.sale
              ? _SaleSection(margin: margin, rights: rights)
              : _CustomersSection(margin: margin, rights: rights),
        ),
      ],
    );
  }
}

/// État de la caisse, toujours visible : ouvrir / clôturer (rapport Z).
class _CashBar extends ConsumerWidget {
  const _CashBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(currentCashSessionProvider);
    return session.when(
      loading: () => const SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
      error: (error, _) => AmpereBadge(
        label: 'Caisse indisponible',
        tone: StatusTone.warn,
        icon: LucideIcons.cloudOff,
      ),
      data: (cash) => cash == null
          ? OutlinedButton.icon(
              onPressed: () => _openCash(context, ref),
              icon: const Icon(LucideIcons.lockOpen, size: 17),
              label: const Text('Ouvrir la caisse'),
            )
          : Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                AmpereBadge(
                  label: 'Caisse ouverte · ${formatDA(cash.currentAmount)}',
                  tone: StatusTone.ok,
                ),
                TextButton(
                  onPressed: () => _closeCash(context, ref, cash),
                  child: const Text('Clôturer'),
                ),
              ],
            ),
    );
  }

  Future<void> _openCash(BuildContext context, WidgetRef ref) async {
    final store = (ref.read(locationsProvider).value ?? const [])
        .where((l) => l.type == 'MAGASIN' && l.isActive)
        .firstOrNull;
    if (store == null) {
      _snack(context, 'Magasin introuvable dans le catalogue local');
      return;
    }
    final amount = await _askAmount(
      context,
      title: 'Ouvrir la caisse',
      label: 'Fond de caisse',
      confirm: 'Ouvrir',
    );
    if (amount == null || !context.mounted) return;
    try {
      await ref.read(salesActionsProvider).openCash(store.id, amount);
      if (context.mounted) _snack(context, 'Caisse ouverte.');
    } on ApiException catch (error) {
      if (context.mounted) _snack(context, error.userMessage);
    }
  }

  Future<void> _closeCash(
    BuildContext context,
    WidgetRef ref,
    CashSession cash,
  ) async {
    final counted = await _askAmount(
      context,
      title: 'Clôturer la caisse',
      label: 'Espèces comptées dans le tiroir',
      confirm: 'Clôturer',
      help: 'Attendu : ${formatDA(cash.currentAmount)}',
    );
    if (counted == null || !context.mounted) return;
    try {
      final report = await ref
          .read(salesActionsProvider)
          .closeCash(cash.id, counted);
      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Rapport Z'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Fond : ${formatDA(report.openingFloat)}'),
              Text(
                'Ventes espèces : ${formatDA(report.cashSalesAmount)} '
                '(${report.cashSalesCount})',
              ),
              Text('Entrées totales : ${formatDA(report.cashInAmount)}'),
              Text('Sorties : ${formatDA(report.cashOutAmount)}'),
              Text('Attendu : ${formatDA(report.expectedAmount ?? 0)}'),
              Text('Compté : ${formatDA(report.countedAmount ?? 0)}'),
              const SizedBox(height: 6),
              Text(
                'Écart : ${formatDA(report.difference ?? 0)}',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Fermer'),
            ),
          ],
        ),
      );
    } on ApiException catch (error) {
      if (context.mounted) _snack(context, error.userMessage);
    }
  }
}

/// Saisie d'un montant en DA (virgule acceptée), renvoyé en centimes.
Future<int?> _askAmount(
  BuildContext context, {
  required String title,
  required String label,
  required String confirm,
  String? help,
  int? initial,
}) {
  final controller = TextEditingController(
    text: initial == null ? '' : formatDA(initial, withSymbol: false),
  );
  return showDialog<int>(
    context: context,
    builder: (context) {
      String? error;
      return StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(title),
          content: TextField(
            controller: controller,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: label,
              suffixText: 'DA',
              helperText: help,
              errorText: error,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Annuler'),
            ),
            FilledButton(
              onPressed: () {
                final value = parseDA(controller.text);
                if (value == null || value < 0) {
                  setState(
                    () => error = 'Montant invalide, ex. 5000 ou 1450,50',
                  );
                  return;
                }
                Navigator.of(context).pop(value);
              },
              child: Text(confirm),
            ),
          ],
        ),
      );
    },
  );
}

class _SaleSection extends ConsumerStatefulWidget {
  const _SaleSection({required this.margin, required this.rights});

  final double margin;
  final SalesRights rights;

  @override
  ConsumerState<_SaleSection> createState() => _SaleSectionState();
}

class _SaleSectionState extends ConsumerState<_SaleSection> {
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  bool _busy = false;

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  /// Douchette USB : le code arrive comme une saisie clavier suivie d'« Entrée ».
  void _scan(String raw, List<Product> products) {
    final code = raw.trim();
    if (code.isEmpty) return;
    final match = products.where((p) => p.barcode == code).firstOrNull;
    if (match == null) {
      _snack(context, 'Aucun produit pour le code $code');
    } else {
      ref.read(cartProvider.notifier).add(match);
    }
    _search.clear();
    _searchFocus.requestFocus();
  }

  Future<void> _checkout(CartEstimate estimate) async {
    final cart = ref.read(cartProvider);
    final received = await _askAmount(
      context,
      title: 'Encaisser ${formatDA(estimate.totalTtc)}',
      label: 'Espèces reçues',
      confirm: 'Valider la vente',
      initial: estimate.totalTtc,
      help: cart.customer == null
          ? 'Vente comptoir : doit être soldée'
          : 'Moins que le total : le reste part en crédit de ${cart.customer!.name}',
    );
    if (received == null || !mounted) return;
    final kept = received < estimate.totalTtc ? received : estimate.totalTtc;
    setState(() => _busy = true);
    try {
      final sale = await ref
          .read(salesActionsProvider)
          .checkout(kept, expectedTotalTtc: estimate.totalTtc);
      if (!mounted) return;
      final change = received - kept;
      await _showTicket(sale, change: change);
    } on ApiException catch (error) {
      if (error.code == ErrorCodes.saleTotalChanged) {
        // Prix changé entre-temps : le catalogue local est remis à jour.
        ref.read(catalogSyncProvider.notifier).refresh();
      } else if (error.code == ErrorCodes.saleAlreadyRecorded) {
        // La vente précédente EXISTE : ce panier ne doit pas la réécrire en
        // boucle ; il repart avec un nouvel id, le vendeur vérifie d'abord.
        ref.read(cartProvider.notifier).clear();
        ref.invalidate(mySalesProvider);
        ref.invalidate(currentCashSessionProvider);
      }
      if (mounted) _snack(context, error.userMessage);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showTicket(Sale sale, {required int change}) {
    return showDialog<void>(
      context: context,
      builder: (context) => _TicketDialog(
        sale: sale,
        change: change,
        canInvoice: widget.rights.canInvoice,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    final cart = ref.watch(cartProvider);
    final estimate = ref.watch(cartEstimateProvider);
    final products = ref.watch(activeProductsProvider).value ?? const [];
    final cash = ref.watch(currentCashSessionProvider).value;

    if (!widget.rights.canSell) {
      return const ScreenStateView(
        status: ScreenStatus.empty,
        title: 'Vente réservée aux vendeurs',
      );
    }

    final sync = ref.watch(catalogSyncProvider);
    return ListView(
      padding: EdgeInsets.fromLTRB(widget.margin, 14, widget.margin, 24),
      children: [
        // Catalogue local encore vide (poste neuf) : on dit pourquoi, au lieu
        // de laisser croire qu'aucun produit n'existe.
        if (products.isEmpty) ...[
          AmpereInlineAlert(
            tone: sync.hasError ? StatusTone.error : StatusTone.info,
            message: sync.isLoading
                ? 'Chargement du catalogue…'
                : sync.hasError
                ? 'Catalogue non chargé : vérifiez la connexion.'
                : 'Le catalogue ne contient aucun produit actif.',
            action: sync.hasError
                ? TextButton(
                    onPressed: () =>
                        ref.read(catalogSyncProvider.notifier).refresh(),
                    child: const Text('Réessayer'),
                  )
                : null,
          ),
          const SizedBox(height: 12),
        ],
        Autocomplete<Product>(
          displayStringForOption: (p) => p.name,
          optionsBuilder: (value) {
            final term = foldForSearch(value.text);
            if (term.length < 2) return const Iterable<Product>.empty();
            return products
                .where(
                  (p) => foldForSearch(
                    '${p.name} ${p.sku} ${p.barcode}',
                  ).contains(term),
                )
                .take(20);
          },
          onSelected: (p) {
            ref.read(cartProvider.notifier).add(p);
            _search.clear();
          },
          fieldViewBuilder: (context, controller, focus, _) {
            // Le champ de l'Autocomplete sert aussi à la douchette.
            return TextField(
              controller: controller,
              focusNode: focus,
              autofocus: true,
              autocorrect: false,
              style: AmpereType.input.copyWith(color: colors.ink),
              decoration: const InputDecoration(
                prefixIcon: Icon(LucideIcons.scanBarcode, size: 17),
                hintText: 'Scanner un code-barres ou chercher un produit',
              ),
              onSubmitted: (value) {
                _scan(value, products);
                controller.clear();
              },
            );
          },
        ),
        const SizedBox(height: 12),
        _CustomerPicker(customer: cart.customer),
        const SizedBox(height: 12),
        if (cart.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: ScreenStateView(
              status: ScreenStatus.empty,
              title: 'Panier vide',
              message: 'Scannez ou cherchez un produit pour commencer.',
            ),
          )
        else
          for (final line in cart.lines)
            _CartLineRow(
              line: line,
              missingPrice: estimate.missingPrices.contains(line.product),
              totalHt: estimate.lineTotalsHt[line.product.id],
            ),
        if (!cart.isEmpty) ...[
          const Divider(height: 28),
          _TotalRow('Total HT', estimate.totalHt),
          _TotalRow('TVA', estimate.totalTax),
          _TotalRow('Total TTC', estimate.totalTtc, strong: true),
          Text(
            'Estimation — le montant exact est calculé par le serveur.',
            style: AmpereType.meta.copyWith(color: colors.ink3),
          ),
          if (estimate.missingPrices.isNotEmpty) ...[
            const SizedBox(height: 10),
            const AmpereInlineAlert(
              message:
                  'Certains produits n’ont pas de prix pour ce tarif : '
                  'la vente sera refusée.',
            ),
          ],
          if (cash == null && cart.customer == null) ...[
            const SizedBox(height: 10),
            const AmpereInlineAlert(
              tone: StatusTone.warn,
              message: 'Ouvrez la caisse pour encaisser des espèces.',
            ),
          ],
          const SizedBox(height: 16),
          SizedBox(
            height: AmpereGeometry.touchPrimary,
            child: FilledButton.icon(
              onPressed: _busy || estimate.missingPrices.isNotEmpty
                  ? null
                  : () => _checkout(estimate),
              icon: const Icon(LucideIcons.banknote, size: 18),
              label: Text('Encaisser ${formatDA(estimate.totalTtc)}'),
            ),
          ),
          TextButton(
            onPressed: _busy
                ? null
                : () => ref.read(cartProvider.notifier).clear(),
            child: const Text('Vider le panier'),
          ),
        ],
      ],
    );
  }
}

class _TotalRow extends StatelessWidget {
  const _TotalRow(this.label, this.amount, {this.strong = false});

  final String label;
  final int amount;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    final style = (strong ? AmpereType.sectionTitle : AmpereType.body).copyWith(
      color: colors.ink,
      fontFeatures: AmpereType.tabular,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(child: Text(label, style: style)),
          Text(formatDA(amount), style: style),
        ],
      ),
    );
  }
}

class _CartLineRow extends ConsumerWidget {
  const _CartLineRow({
    required this.line,
    required this.missingPrice,
    this.totalHt,
  });

  final CartLine line;
  final bool missingPrice;
  final int? totalHt;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = AmpereColors.of(context);
    final cart = ref.read(cartProvider.notifier);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  line.product.name,
                  style: AmpereType.rowTitle.copyWith(color: colors.ink),
                ),
                Text(
                  totalHt == null
                      ? line.product.sku
                      : '${line.product.sku} · ${formatDA(totalHt!)} HT',
                  style: AmpereType.mono.copyWith(color: colors.ink3),
                ),
                if (missingPrice)
                  const AmpereBadge(
                    label: 'Prix non fixé',
                    tone: StatusTone.error,
                  ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Moins',
            icon: const Icon(LucideIcons.minus, size: 17),
            onPressed: () =>
                cart.setQuantity(line.product.id, line.quantity - Quantity.one),
          ),
          SizedBox(
            width: 72,
            child: Text(
              '${formatQuantity(line.quantity)} ${line.product.unit.short}',
              textAlign: TextAlign.center,
              style: AmpereType.bodyStrong.copyWith(
                color: colors.ink,
                fontFeatures: AmpereType.tabular,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Plus',
            icon: const Icon(LucideIcons.plus, size: 17),
            onPressed: () => cart.add(line.product),
          ),
          IconButton(
            tooltip: 'Retirer',
            icon: Icon(LucideIcons.trash2, size: 17, color: colors.error),
            onPressed: () => cart.setQuantity(line.product.id, Quantity.zero),
          ),
        ],
      ),
    );
  }
}

class _CustomerPicker extends ConsumerWidget {
  const _CustomerPicker({required this.customer});

  final Customer? customer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chosen = customer;
    if (chosen != null) {
      return AmpereInlineAlert(
        tone: StatusTone.info,
        icon: LucideIcons.user,
        message:
            '${chosen.name} · dette ${formatDA(chosen.balanceDue)} · '
            'plafond ${formatDA(chosen.creditLimit)}',
        action: TextButton(
          onPressed: () => ref.read(cartProvider.notifier).setCustomer(null),
          child: const Text('Retirer'),
        ),
      );
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: OutlinedButton.icon(
        onPressed: () async {
          final picked = await showDialog<Customer>(
            context: context,
            builder: (_) => const _CustomerSearchDialog(),
          );
          if (picked != null) {
            ref.read(cartProvider.notifier).setCustomer(picked);
          }
        },
        icon: const Icon(LucideIcons.userSearch, size: 17),
        label: const Text('Client (facultatif)'),
      ),
    );
  }
}

class _CustomerSearchDialog extends ConsumerStatefulWidget {
  const _CustomerSearchDialog();

  @override
  ConsumerState<_CustomerSearchDialog> createState() =>
      _CustomerSearchDialogState();
}

class _CustomerSearchDialogState extends ConsumerState<_CustomerSearchDialog> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final results = ref.watch(customerSearchProvider(_query));
    return AlertDialog(
      title: const Text('Choisir un client'),
      content: SizedBox(
        width: 420,
        height: 360,
        child: Column(
          children: [
            TextField(
              autofocus: true,
              decoration: const InputDecoration(
                prefixIcon: Icon(LucideIcons.search, size: 17),
                hintText: 'Nom ou téléphone',
              ),
              onChanged: (v) => setState(() => _query = v.trim()),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: results.when(
                loading: () => const AmpereSkeletonList(rows: 4),
                error: (error, _) =>
                    AmpereInlineAlert(message: _errorText(error)),
                data: (customers) => ListView(
                  children: [
                    for (final c in customers)
                      ListTile(
                        title: Text(c.name),
                        subtitle: Text(
                          '${c.phone ?? ''} · dette ${formatDA(c.balanceDue)}',
                        ),
                        onTap: () => Navigator.of(context).pop(c),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Annuler'),
        ),
      ],
    );
  }
}

class _TicketDialog extends ConsumerStatefulWidget {
  const _TicketDialog({
    required this.sale,
    required this.change,
    required this.canInvoice,
  });

  final Sale sale;
  final int change;
  final bool canInvoice;

  @override
  ConsumerState<_TicketDialog> createState() => _TicketDialogState();
}

class _TicketDialogState extends ConsumerState<_TicketDialog> {
  late Sale _sale = widget.sale;
  bool _busy = false;

  Future<void> _print() async {
    setState(() => _busy = true);
    try {
      await ref.read(salesActionsProvider).printDocument(_sale);
    } on ApiException catch (error) {
      if (mounted) _snack(context, error.userMessage);
    } catch (_) {
      // Boîte d'impression indisponible (plateforme, aucune imprimante…).
      if (mounted) _snack(context, 'Impression impossible sur cet appareil');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final names = {
      for (final p in ref.watch(activeProductsProvider).value ?? const [])
        p.id: p.name,
    };
    return AlertDialog(
      title: Text(_sale.invoiceNumber ?? _sale.number),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final line in _sale.lines)
              Text(
                '${formatQuantity(line.quantity)} × ${names[line.productId] ?? 'Produit'} '
                '— ${formatDA(line.lineTotalTtc)}',
              ),
            const Divider(),
            Text('Total TTC : ${formatDA(_sale.totalTtc)}'),
            Text('Encaissé : ${formatDA(_sale.paidAmount)}'),
            if (widget.change > 0)
              Text(
                'Monnaie à rendre : ${formatDA(widget.change)}',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            if (_sale.remainingAmount > 0)
              Text('Reste dû (crédit) : ${formatDA(_sale.remainingAmount)}'),
          ],
        ),
      ),
      actions: [
        if (widget.canInvoice && _sale.invoiceNumber == null)
          OutlinedButton(
            onPressed: _busy
                ? null
                : () async {
                    setState(() => _busy = true);
                    try {
                      final invoiced = await ref
                          .read(salesActionsProvider)
                          .invoice(_sale.id);
                      if (mounted) setState(() => _sale = invoiced);
                    } on ApiException catch (error) {
                      if (context.mounted) _snack(context, error.userMessage);
                    } finally {
                      if (mounted) setState(() => _busy = false);
                    }
                  },
            child: const Text('Émettre la facture'),
          ),
        OutlinedButton.icon(
          onPressed: _busy ? null : _print,
          icon: const Icon(LucideIcons.printer, size: 16),
          label: Text(
            _sale.invoiceNumber == null
                ? 'Imprimer le ticket'
                : 'Imprimer la facture',
          ),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Nouvelle vente'),
        ),
      ],
    );
  }
}

class _CustomersSection extends ConsumerStatefulWidget {
  const _CustomersSection({required this.margin, required this.rights});

  final double margin;
  final SalesRights rights;

  @override
  ConsumerState<_CustomersSection> createState() => _CustomersSectionState();
}

class _CustomersSectionState extends ConsumerState<_CustomersSection> {
  String _query = '';

  Future<void> _create() async {
    final name = TextEditingController();
    final phone = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Nouveau client'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Nom'),
            ),
            TextField(
              controller: phone,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(labelText: 'Téléphone'),
            ),
            const SizedBox(height: 8),
            const Text(
              'Tarif et plafond de crédit sont fixés par l’administrateur.',
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Créer'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      final created = await ref
          .read(salesActionsProvider)
          .createCustomer(
            name.text.trim(),
            phone.text.trim().isEmpty ? null : phone.text.trim(),
          );
      if (mounted) _snack(context, 'Client ${created.name} créé.');
    } on ApiException catch (error) {
      if (mounted) _snack(context, error.userMessage);
    }
  }

  Future<void> _pay(Customer customer) async {
    final amount = await _askAmount(
      context,
      title: 'Règlement de ${customer.name}',
      label: 'Espèces reçues',
      confirm: 'Encaisser',
      initial: customer.balanceDue,
      help: 'Dette : ${formatDA(customer.balanceDue)}',
    );
    if (amount == null || amount == 0 || !mounted) return;
    try {
      // Même clé à chaque essai de ce règlement, dialogue rouvert compris.
      await _retryable(
        () => ref.read(salesActionsProvider).payCustomer(customer.id, amount),
      );
      if (mounted) {
        _snack(context, 'Règlement de ${formatDA(amount)} encaissé.');
      }
    } on ApiException catch (error) {
      if (mounted) _snack(context, error.userMessage);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    final customers = ref.watch(customerSearchProvider(_query));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(widget.margin, 14, widget.margin, 10),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  style: AmpereType.input.copyWith(color: colors.ink),
                  decoration: const InputDecoration(
                    prefixIcon: Icon(LucideIcons.search, size: 17),
                    hintText: 'Nom ou téléphone',
                  ),
                  onChanged: (v) => setState(() => _query = v.trim()),
                ),
              ),
              if (widget.rights.canWriteCustomers) ...[
                const SizedBox(width: 12),
                FilledButton.icon(
                  onPressed: _create,
                  icon: const Icon(LucideIcons.plus, size: 17),
                  label: const Text('Nouveau client'),
                ),
              ],
            ],
          ),
        ),
        Expanded(
          child: customers.when(
            loading: () => const AmpereSkeletonList(rows: 5),
            error: (error, _) => ScreenStateView(
              status: error is ApiException && error.isOffline
                  ? ScreenStatus.offline
                  : ScreenStatus.error,
              message: _errorText(error),
              onRetry: () => ref.invalidate(customerSearchProvider),
            ),
            data: (items) => items.isEmpty
                ? ScreenStateView(
                    status: _query.isEmpty
                        ? ScreenStatus.empty
                        : ScreenStatus.noResults,
                    title: _query.isEmpty ? 'Aucun client' : null,
                    searchTerm: _query.isEmpty ? null : _query,
                  )
                : ListView(
                    padding: EdgeInsets.fromLTRB(
                      widget.margin,
                      0,
                      widget.margin,
                      24,
                    ),
                    children: [
                      for (final c in items)
                        Card(
                          child: ListTile(
                            title: Text(c.name),
                            subtitle: Text(
                              '${c.phone ?? 'Sans téléphone'} · plafond '
                              '${formatDA(c.creditLimit)}',
                            ),
                            trailing: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                AmpereBadge(
                                  label: c.balanceDue > 0
                                      ? 'Dette ${formatDA(c.balanceDue)}'
                                      : 'À jour',
                                  tone: c.balanceDue > 0
                                      ? StatusTone.warn
                                      : StatusTone.ok,
                                ),
                              ],
                            ),
                            onTap:
                                widget.rights.canTakePayments &&
                                    c.balanceDue > 0
                                ? () => _pay(c)
                                : null,
                          ),
                        ),
                    ],
                  ),
          ),
        ),
      ],
    );
  }
}
