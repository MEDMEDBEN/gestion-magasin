import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/dates.dart';
import '../../../core/error/api_exception.dart';
import '../../../core/error/error_codes.dart';
import '../../../core/money.dart';
import '../../../core/offline_write.dart';
import '../../../core/quantity.dart';
import '../../../ui/breakpoints.dart';
import '../../../ui/theme/ampere_colors.dart';
import '../../../ui/theme/ampere_typography.dart';
import '../../../core/file_export.dart';
import '../../../core/file_import.dart';
import '../../../ui/widgets/amount_dialog.dart';
import '../../../ui/widgets/form_panel.dart';
import '../../../ui/widgets/fields_dialog.dart';
import '../../../ui/widgets/history_dialog.dart';
import '../../../ui/widgets/import_button.dart';
import '../../../ui/widgets/pill_tabs.dart';
import '../../../ui/widgets/export_button.dart';
import '../../../ui/widgets/feedback_burst.dart';
import '../../../ui/widgets/glass.dart';
import '../../../ui/widgets/screen_state.dart';
import '../../auth/data/auth_models.dart';
import '../../catalog/application/catalog_controller.dart';
import '../../catalog/data/catalog_models.dart';
import '../../catalog/presentation/product_photo.dart';
import '../../scan/presentation/scanned_product_sheet.dart';
import '../../catalog/data/catalog_repository.dart';
import '../../payments/presentation/payment_history_dialog.dart';
import '../../quotes/application/quotes_controller.dart';
import '../application/sales_controller.dart';
import '../data/sales_api.dart';
import '../data/sales_models.dart';
import '../../scan/presentation/scan_screen.dart';
import '../../../ui/widgets/ampere_controls.dart';
import '../../../ui/widgets/contact_profile.dart';
import '../../../ui/widgets/discount_dialog.dart';
import 'buyer_picker.dart';
import 'confreres_section.dart';
import 'contact_card.dart';
import '../../stock/application/stock_controller.dart';
import 'customer_form.dart';
import 'payment_dialog.dart';
import 'sales_history.dart';

/// Droits de la vente, MIROIRS des guards serveur (`docs/permissions.md`).
class SalesRights {
  SalesRights(AuthUser user)
    : canSell =
          (user.hasRole('ADMIN') || user.hasRole('VENDEUR')) &&
          user.can('sale.create'),
      // Miroir exact de `POST /sales/:id/invoice` : ADMIN|VENDEUR + invoice.issue.
      canInvoice =
          (user.hasRole('ADMIN') || user.hasRole('VENDEUR')) &&
          user.can('invoice.issue'),
      canManageCash = user.can('cash.session.manage'),
      canWriteCustomers = user.can('customer.write'),
      // `POST /imports/customers` : ADMIN + customer.write (saisie en masse).
      canImportCustomers = user.hasRole('ADMIN') && user.can('customer.write'),
      // `PATCH /customers/:id` avec isActive : ADMIN seul (2026-10-06).
      canDeleteCustomers = user.hasRole('ADMIN') && user.can('customer.write'),
      canTakePayments = user.can('customer.payment.create'),
      canReversePayments =
          user.hasRole('ADMIN') && user.can('customer.payment.create'),
      canSeeAllCash = user.hasRole('ADMIN') && user.can('cash.report.read'),
      canCancelSales = user.hasRole('ADMIN') && user.can('sale.cancel'),
      // Remise sur une ligne : ADMIN + sale.discount (miroir du serveur).
      canDiscount = user.hasRole('ADMIN') && user.can('sale.discount'),
      // Tarif et plafond de crédit d'un client : conditions commerciales.
      canManageCustomerTerms =
          user.hasRole('ADMIN') && user.can('price.manage'),
      // Relevé de compte : ADMIN + customer.read (tout le CA d'un client).
      canReadStatements = user.hasRole('ADMIN') && user.can('customer.read'),
      // Profit d'une vente (décision MEDMEDBEN du 2026-10-12) : admin et
      // vendeur, qui voient déjà le prix d'achat (`cost.read`).
      canSeeProfit =
          (user.hasRole('ADMIN') || user.hasRole('VENDEUR')) &&
          user.can('cost.read'),
      // `/confreres` : ADMIN|VENDEUR + customer.read (2026-10-08).
      canSeeConfreres =
          (user.hasRole('ADMIN') || user.hasRole('VENDEUR')) &&
          user.can('customer.read'),
      // Verser à un confrère = `POST /payments/supplier` : ADMIN.
      canPayConfreres =
          user.hasRole('ADMIN') && user.can('supplier.payment.create');

  final bool canSell;
  final bool canSeeConfreres;
  final bool canPayConfreres;
  final bool canInvoice;
  final bool canManageCash;
  final bool canWriteCustomers;
  final bool canImportCustomers;

  /// « Supprimer » un client = le retirer des listes (historique conservé).
  final bool canDeleteCustomers;
  final bool canTakePayments;

  /// Contre-passation d'un règlement : ADMIN (miroir du guard serveur).
  final bool canReversePayments;

  /// Liste de toutes les caisses : ADMIN + cash.report.read.
  final bool canSeeAllCash;

  /// Annulation d'une vente : ADMIN + sale.cancel (miroir du guard serveur).
  final bool canCancelSales;
  final bool canDiscount;
  final bool canManageCustomerTerms;
  final bool canReadStatements;
  final bool canSeeProfit;
}

enum _Section { sale, history, customers, confreres, cashSessions }

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

String _errorText(Object error) =>
    error is ApiException ? error.userMessage : 'Action impossible';

/// Vente au comptoir : caisse, panier (recherche ou douchette), client,
/// encaissement espèces / crédit, ticket et facture. Le serveur valide tout
/// (prix, stock, caisse, plafond) ; sans réseau, vente, caisse et règlements
/// partent dans la file et sont jugés à la synchronisation (P0 n°12).
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
    // Marges réduites (2026-10-12) : la place va aux produits et au ticket.
    final margin = isDesktop ? 16.0 : AmpereGeometry.screenMarginMobile;

    final tabs = Align(
      alignment: Alignment.centerLeft,
      child: PillTabs<_Section>(
        selected: _section,
        onSelect: (section) => setState(() => _section = section),
        items: [
          (_Section.sale, LucideIcons.shoppingCart, 'Vente'),
          // Miroir de `GET /sales` : ADMIN|VENDEUR + sale.create.
          if (rights.canSell)
            (_Section.history, LucideIcons.history, 'Historique'),
          (_Section.customers, LucideIcons.users, 'Clients'),
          if (rights.canSeeConfreres)
            (_Section.confreres, LucideIcons.handshake, 'Confrères'),
          if (rights.canSeeAllCash)
            (_Section.cashSessions, LucideIcons.landmark, 'Caisses'),
        ],
      ),
    );

    // Vente (demande MEDMEDBEN du 2026-10-14) : pas de bandeau au-dessus — les
    // onglets vont en tête de la colonne des produits, et le PANIER monte
    // jusqu'à la barre du haut.
    if (_section == _Section.sale) {
      return _SaleSection(margin: margin, rights: rights, tabs: tabs);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(margin, 8, margin, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: tabs),
              // L'export des ventes ne sert qu'à l'historique : il n'est
              // proposé que là. Miroir de `GET /sales/export` : ADMIN|VENDEUR
              // + `sale.create` ; le vendeur n'y trouve que SES ventes.
              if (_section == _Section.history && rights.canSell) ...[
                const SizedBox(width: 8),
                ExportButton(
                  targets: [
                    ExportTarget(
                      'Ventes (90 jours)',
                      ref.read(salesApiProvider).exportSales,
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
        Expanded(
          child: switch (_section) {
            _Section.sale => const SizedBox.shrink(),
            _Section.history => SalesHistorySection(
              margin: margin,
              rights: rights,
            ),
            _Section.customers => _CustomersSection(
              margin: margin,
              rights: rights,
              onSell: (customer) {
                ref.read(cartProvider.notifier).setCustomer(customer);
                setState(() => _section = _Section.sale);
              },
            ),
            _Section.confreres => ConfreresSection(
              margin: margin,
              canPayConfreres: rights.canPayConfreres,
              onSell: (customer) {
                ref.read(cartProvider.notifier).setCustomer(customer);
                setState(() => _section = _Section.sale);
              },
            ),
            _Section.cashSessions => _CashSessionsSection(margin: margin),
          },
        ),
      ],
    );
  }
}

/// Ouvrir la caisse : le fond de caisse du jour, AVANT toute vente ou sortie
/// (une caisse ne vit qu'un jour — décision MEDMEDBEN du 2026-10-08).
Future<void> _openCashFlow(BuildContext context, WidgetRef ref) async {
  final store = (ref.read(locationsProvider).value ?? const [])
      .where((l) => l.type == 'MAGASIN' && l.isActive)
      .firstOrNull;
  if (store == null) {
    _snack(context, 'Magasin introuvable dans le catalogue local');
    return;
  }
  final amount = await askAmount(
    context,
    title: 'Ouvrir la caisse du jour',
    label: 'Fond de caisse (espèces dans le tiroir)',
    help: 'Comptez le tiroir avant la première vente.',
    confirm: 'Ouvrir',
  );
  if (amount == null || !context.mounted) return;
  try {
    final outcome = await ref
        .read(salesActionsProvider)
        .openCash(store.id, amount);
    if (context.mounted) {
      _snack(
        context,
        outcome is Queued
            ? 'Caisse ouverte sur cet appareil — en attente de synchronisation.'
            : 'Caisse ouverte.',
      );
    }
  } on ApiException catch (error) {
    if (context.mounted) _snack(context, error.userMessage);
  }
}

/// État de la caisse, toujours visible : une carte « tiroir » — ce qu'il y a
/// dedans, mouvements, clôture (rapport Z) ; fermée, elle invite à l'ouvrir.
class _CashBar extends ConsumerWidget {
  const _CashBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = AmpereColors.of(context);
    final session = ref.watch(currentCashSessionProvider);
    // Gardé en vie : « Ouvrir la caisse » y cherche le magasin. Lu seulement au
    // clic, ce provider auto-libéré était encore vide (« Magasin introuvable »).
    ref.watch(locationsProvider);
    return session.when(
      loading: () => const SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
      // Caisse INCONNUE (hors ligne, jamais lue sur cet appareil) : on ne
      // propose pas d'en ouvrir une — elle l'est peut-être déjà au serveur.
      error: (error, _) => AmpereBadge(
        label: 'Caisse indisponible',
        tone: StatusTone.warn,
        icon: LucideIcons.cloudOff,
      ),
      data: (cash) => cash == null
          ? _DrawerCard(
              tone: colors.warn,
              icon: LucideIcons.lock,
              title: 'Caisse fermée',
              subtitle:
                  'Saisissez le fond de caisse du jour avant la première '
                  'vente ou sortie.',
              trailing: FilledButton.icon(
                onPressed: () => _openCashFlow(context, ref),
                icon: const Icon(LucideIcons.lockOpen, size: 17),
                label: const Text('Ouvrir la caisse'),
              ),
            )
          : cash.status == cashPendingSync
          // Pas de mouvement sur une caisse encore en file : le serveur ne la
          // connaît pas.
          ? _DrawerCard(
              tone: colors.warn,
              icon: LucideIcons.refreshCw,
              title: 'Caisse ouverte · en attente de synchronisation',
              subtitle: 'Fond : ${formatDA(cash.openingFloat)}',
              trailing: TextButton(
                onPressed: () => _closeCash(context, ref, cash),
                child: const Text('Clôturer'),
              ),
            )
          : _DrawerCard(
              tone: colors.ok,
              icon: LucideIcons.wallet,
              title: 'Caisse ouverte · ${formatDA(cash.currentAmount)}',
              subtitle:
                  'Depuis ${formatTime(cash.openedAt)} · fond '
                  '${formatDA(cash.openingFloat)}',
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  PopupMenuButton<String>(
                    tooltip: 'Mouvement de caisse',
                    icon: const Icon(LucideIcons.arrowLeftRight, size: 17),
                    onSelected: (type) =>
                        _cashMovement(context, ref, cash, type),
                    itemBuilder: (context) => const [
                      PopupMenuItem(
                        value: 'ENTREE',
                        child: Text('Entrée d’espèces'),
                      ),
                      PopupMenuItem(
                        value: 'SORTIE',
                        child: Text('Sortie (dépense)'),
                      ),
                      PopupMenuItem(
                        value: 'PRELEVEMENT',
                        child: Text('Prélèvement (coffre, banque)'),
                      ),
                    ],
                  ),
                  TextButton(
                    onPressed: () => _closeCash(context, ref, cash),
                    child: const Text('Clôturer'),
                  ),
                ],
              ),
            ),
    );
  }

  /// Entrée, sortie ou prélèvement : montant, puis motif (obligatoire).
  Future<void> _cashMovement(
    BuildContext context,
    WidgetRef ref,
    CashSession cash,
    String type,
  ) async {
    const titles = {
      'ENTREE': 'Entrée d’espèces',
      'SORTIE': 'Sortie d’espèces',
      'PRELEVEMENT': 'Prélèvement',
    };
    final amount = await askAmount(
      context,
      title: titles[type]!,
      label: 'Montant',
      confirm: 'Continuer',
      help: 'Dans le tiroir : ${formatDA(cash.currentAmount)}',
    );
    if (amount == null || amount <= 0 || !context.mounted) return;
    final note = (await askFields(
      context,
      title: '${titles[type]!} de ${formatDA(amount)}',
      fields: const [(key: 'note', label: 'Motif', initial: '')],
    ))?['note'];
    if (note == null || !context.mounted) return;
    if (note.length < 2) {
      _snack(context, 'Motif obligatoire');
      return;
    }
    try {
      final after = await ref
          .read(salesActionsProvider)
          .cashMovement(cash.id, type: type, amount: amount, note: note);
      if (context.mounted) {
        _snack(
          context,
          '${titles[type]!} enregistrée — tiroir : ${formatDA(after.currentAmount)}',
        );
      }
    } on ApiException catch (error) {
      if (context.mounted) _snack(context, error.userMessage);
    }
  }

  Future<void> _closeCash(
    BuildContext context,
    WidgetRef ref,
    CashSession cash,
  ) async {
    final counted = await askAmount(
      context,
      title: 'Clôturer la caisse',
      label: 'Espèces comptées dans le tiroir',
      confirm: 'Clôturer',
      help: 'Attendu : ${formatDA(cash.currentAmount)}',
    );
    if (counted == null || !context.mounted) return;
    try {
      final outcome = await ref
          .read(salesActionsProvider)
          .closeCash(cash.id, counted);
      if (!context.mounted) return;
      switch (outcome) {
        case Applied(value: final report):
          await _showZReport(context, report);
        case Queued():
          // Le serveur n'a encore rien calculé : pas de rapport Z, jamais un
          // écart inventé côté appareil.
          await showDialog<void>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Clôture en attente de synchronisation'),
              content: Text(
                'Compté : ${formatDA(counted)}. La clôture partira après les '
                'opérations encore en attente ; le rapport Z (attendu, écart) '
                'sera disponible une fois synchronisée.',
              ),
              actions: [
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Compris'),
                ),
              ],
            ),
          );
      }
    } on ApiException catch (error) {
      if (context.mounted) _snack(context, error.userMessage);
    }
  }
}

/// Bandeau « tiroir-caisse » du ticket : UNE ligne teintée par l'état
/// (icône, titre, gestes), le détail en infobulle — la place va aux produits
/// du panier (demande MEDMEDBEN du 2026-10-09).
class _DrawerCard extends StatelessWidget {
  const _DrawerCard({
    required this.tone,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.trailing,
  });

  final Color tone;
  final IconData icon;
  final String title;
  final String subtitle;
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    return Tooltip(
      message: subtitle,
      child: Container(
        // Sobre (maquette du 2026-10-26) : carte blanche à filet, seule
        // l'icône dit l'état de la caisse.
        padding: const EdgeInsets.fromLTRB(10, 0, 2, 0),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: colors.surface,
          border: Border.all(color: colors.line),
        ),
        child: Row(
          children: [
            Icon(icon, size: 18, color: tone),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AmpereType.bodyStrong.copyWith(color: colors.ink),
              ),
            ),
            trailing,
          ],
        ),
      ),
    );
  }
}

const _movementLabel = {
  'ENTREE': 'Entrée',
  'SORTIE': 'Sortie',
  'PRELEVEMENT': 'Prélèvement',
};

/// Rapport Z d'une session (clôture ou consultation admin).
Future<void> _showZReport(BuildContext context, CashSession report) {
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(
        report.userFullName == null
            ? 'Rapport Z'
            : 'Rapport Z — ${report.userFullName}',
      ),
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
          // Clôture automatique (changement de jour) : rien n'a été compté —
          // ni « 0 compté » ni écart inventé.
          Text(
            report.countedAmount == null
                ? 'Compté : non comptée'
                : 'Compté : ${formatDA(report.countedAmount!)}',
          ),
          const SizedBox(height: 6),
          Text(
            report.difference == null
                ? 'Écart : —'
                : 'Écart : ${formatDA(report.difference!)}',
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          if (report.countedAmount == null)
            const Text('Clôture automatique (changement de jour).'),
          if (report.movements.isNotEmpty) ...[
            const Divider(height: 20),
            const Text('Mouvements hors vente'),
            for (final m in report.movements)
              Text(
                '${formatDateTime(m.createdAt)} · ${_movementLabel[m.type] ?? m.type} '
                '${formatDA(m.amount)} · ${m.userFullName}'
                '${m.note == null ? '' : ' · ${m.note}'}',
              ),
          ],
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
}

/// Toutes les caisses (ADMIN) : qui, quand, attendu / compté / écart.
class _CashSessionsSection extends ConsumerWidget {
  const _CashSessionsSection({required this.margin});

  final double margin;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessions = ref.watch(cashSessionsProvider);
    return sessions.when(
      loading: () => const AmpereSkeletonList(rows: 5),
      error: (error, _) => ScreenStateView(
        status: error is ApiException && error.isOffline
            ? ScreenStatus.offline
            : ScreenStatus.error,
        message: error is ApiException ? error.userMessage : '$error',
        onRetry: () => ref.invalidate(cashSessionsProvider),
      ),
      data: (items) => items.isEmpty
          ? const ScreenStateView(
              status: ScreenStatus.empty,
              title: 'Aucune caisse ouverte pour l’instant',
            )
          : ListView(
              padding: EdgeInsets.fromLTRB(margin, 14, margin, 24),
              children: [
                for (final s in items)
                  Card(
                    child: ListTile(
                      title: Text(
                        '${s.userFullName ?? 'Caissier'} · '
                        '${formatDateTime(s.openedAt)}',
                      ),
                      subtitle: Text(
                        s.status == 'OUVERTE'
                            ? 'En cours · ${formatDA(s.currentAmount)} dans le tiroir'
                            : 'Attendu ${formatDA(s.expectedAmount ?? 0)} · '
                                  '${s.countedAmount == null ? 'non comptée' : 'compté ${formatDA(s.countedAmount!)}'}',
                      ),
                      trailing: AmpereBadge(
                        label: s.status == 'OUVERTE'
                            ? 'Ouverte'
                            : s.countedAmount == null
                            ? 'Clôture auto'
                            : (s.difference ?? 0) == 0
                            ? 'Juste'
                            : 'Écart ${formatDA(s.difference!)}',
                        tone: s.status == 'OUVERTE'
                            ? StatusTone.info
                            : s.countedAmount == null
                            ? StatusTone.warn
                            : (s.difference ?? 0) == 0
                            ? StatusTone.ok
                            : StatusTone.warn,
                      ),
                      // Rapport complet relu au serveur (détail des mouvements).
                      onTap: () async {
                        try {
                          final report = await ref
                              .read(salesApiProvider)
                              .cashReport(s.id);
                          if (context.mounted) {
                            await _showZReport(context, report);
                          }
                        } on ApiException catch (error) {
                          if (context.mounted) {
                            _snack(context, error.userMessage);
                          }
                        }
                      },
                    ),
                  ),
              ],
            ),
    );
  }
}

class _SaleSection extends ConsumerStatefulWidget {
  const _SaleSection({
    required this.margin,
    required this.rights,
    required this.tabs,
  });

  final double margin;
  final SalesRights rights;

  /// Onglets de l'écran, posés en tête de la colonne des produits.
  final Widget tabs;

  @override
  ConsumerState<_SaleSection> createState() => _SaleSectionState();
}

class _SaleSectionState extends ConsumerState<_SaleSection> {
  /// Filtre de la grille : une catégorie, ou tout (null).
  String? _categoryId;
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
    // MÊME recherche que le scanner mobile : une seule règle de comparaison.
    final match = productForBarcode(products, code);
    if (match == null) {
      _snack(context, 'Aucun produit pour le code $code');
    } else {
      _add(match);
    }
    _search.clear();
    _searchFocus.requestFocus();
  }

  /// Stock CONNU d'un produit au magasin et au dépôt ; `null` hors ligne
  /// ou sans le droit (rien n'est alors affirmé : le serveur jugera).
  ({Quantity store, Quantity depot})? _stockOf(Product product) {
    final stock = ref.read(stockByProductProvider).value;
    final locations = ref.read(locationsProvider).value ?? const [];
    if (stock == null || !locations.any((l) => l.type == 'MAGASIN')) {
      return null;
    }
    Quantity at(String type) => locations
        .where((l) => l.type == type)
        .fold(
          Quantity.zero,
          (sum, l) => sum + (stock[product.id]?.at(l.id) ?? Quantity.zero),
        );
    return (store: at('MAGASIN'), depot: at('DEPOT'));
  }

  /// Lignes du ticket qui dépassent le stock du MAGASIN (règle 9 : le
  /// serveur refusera la vente), sauf produit en « commande autorisée ».
  List<(Product, Quantity)> _shortages(CartState cart) => [
    for (final line in cart.lines)
      if (!line.product.allowBackorder)
        if (_stockOf(line.product) case final s? when s.store < line.quantity)
          (line.product, s.store),
  ];

  /// Ajout au ticket. Plus rien au magasin (demande MEDMEDBEN du
  /// 2026-10-09) : on le DIT, avec le stock du dépôt, et le vendeur choisit —
  /// ne pas l'ajouter, ou l'ajouter quand même (on va le ramener). Le message
  /// précédent part : en bas d'écran, il masquerait le bouton Encaisser.
  Future<void> _add(Product product) async {
    final known = _stockOf(product);
    final inCart =
        ref
            .read(cartProvider)
            .lines
            .where((l) => l.product.id == product.id)
            .firstOrNull
            ?.quantity ??
        Quantity.zero;
    if (known != null && !product.allowBackorder && known.store <= inCart) {
      final unit = product.unit.short;
      final add = await showDialog<bool>(
        context: context,
        builder: (context) {
          final colors = AmpereColors.of(context);
          return AlertDialog(
            constraints: const BoxConstraints(maxWidth: 460),
            icon: Icon(LucideIcons.packageX, color: colors.error, size: 32),
            title: Text(
              known.store <= Quantity.zero
                  ? '« ${product.name} » est en rupture au magasin'
                  : 'Plus de « ${product.name} » au magasin',
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Magasin : ${formatQuantity(known.store)} $unit'
                  '${inCart > Quantity.zero ? ' (déjà ${formatQuantity(inCart)} $unit au ticket)' : ''}'
                  ' · dépôt : ${formatQuantity(known.depot)} $unit',
                  style: AmpereType.bodyStrong.copyWith(color: colors.ink),
                ),
                const SizedBox(height: 10),
                Text(
                  known.depot > Quantity.zero
                      ? 'Vous pouvez l’ajouter si on le ramène du dépôt : la '
                            'vente ne passera qu’une fois la marchandise arrivée '
                            'au magasin.'
                      : 'Le dépôt n’en a pas non plus. La vente sera refusée '
                            'tant qu’il n’est pas réapprovisionné.',
                  style: AmpereType.body.copyWith(color: colors.ink2),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Ne pas l’ajouter'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('L’ajouter quand même'),
              ),
            ],
          );
        },
      );
      if (add != true || !mounted) return;
    }
    ref.read(cartProvider.notifier).add(product);
    if (mounted) ScaffoldMessenger.of(context).hideCurrentSnackBar();
  }

  Future<void> _chooseBuyer() => chooseBuyer(
    context,
    ref,
    withConfreres: widget.rights.canSeeConfreres,
    withSuppliers:
        widget.rights.canSeeConfreres && widget.rights.canWriteCustomers,
  );

  /// Remise sur TOUTE la facture (admin et vendeur, décision du 2026-10-12) :
  /// au plus la marge au-dessus du prix d'achat — le serveur la répartit.
  Future<void> _globalDiscount(CartEstimate estimate) async {
    final cart = ref.read(cartProvider);
    // En DA ou en % du total avant remise (2026-10-12).
    final amount = await askDiscount(
      context,
      title: 'Remise sur toute la facture',
      baseHt: estimate.totalHt + cart.discountHt,
      maxHt: estimate.maxDiscountHt,
      initialHt: cart.discountHt,
    );
    if (amount == null || !mounted) return;
    ref.read(cartProvider.notifier).setGlobalDiscount(amount);
  }

  /// Devis du panier (spec §8quater) : validité proposée à 30 jours ; le
  /// panier est vidé, rien ne sort du stock. En ligne uniquement.
  Future<void> _makeQuote() async {
    final today = DateUtils.dateOnly(DateTime.now());
    final validUntil = await showDatePicker(
      context: context,
      helpText: 'Devis valable jusqu’au',
      initialDate: today.add(const Duration(days: 30)),
      firstDate: today,
      lastDate: today.add(const Duration(days: 365)),
    );
    if (validUntil == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final quote = await ref
          .read(quoteActionsProvider)
          .createFromCart(validUntil: validUntil);
      if (mounted) {
        _snack(
          context,
          'Devis ${quote.number} enregistré (${formatDA(quote.totalTtc)}) — '
          'retrouvez-le dans « Devis ».',
        );
      }
    } on ApiException catch (error) {
      if (mounted) _snack(context, error.userMessage);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Devis BROUILLON corrigé (P1 bis n°21m) : le serveur re-tarife et peut
  /// refuser (devis envoyé entre-temps, prix sous le coût…).
  Future<void> _updateQuote() async {
    setState(() => _busy = true);
    try {
      final quote = await ref.read(quoteActionsProvider).updateFromCart();
      if (mounted) {
        _snack(
          context,
          'Devis ${quote.number} mis à jour (${formatDA(quote.totalTtc)}).',
        );
      }
    } on ApiException catch (error) {
      if (mounted) _snack(context, error.userMessage);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _checkout(CartEstimate estimate) async {
    final cart = ref.read(cartProvider);
    // Caisse CONNUE fermée (dernier état lu, même hors ligne) : une vente
    // comptoir encaisserait des espèces sans caisse — refusée à coup sûr.
    final cashState = ref.read(currentCashSessionProvider);
    if (cart.customer == null &&
        cashState.hasValue &&
        cashState.value == null) {
      _snack(context, 'Ouvrez la caisse avant d’encaisser des espèces');
      return;
    }
    final received = await showPaymentDialog(
      context,
      total: estimate.totalTtc,
      customerName: cart.customer?.name,
    );
    if (received == null || !mounted) return;
    final kept = received < estimate.totalTtc ? received : estimate.totalTtc;
    // Crédit : l'échéance est obligatoire (le serveur la refuse sinon).
    DateTime? dueDate;
    // Entre confrères, l'échéance est facultative (2026-10-08).
    if (kept < estimate.totalTtc &&
        cart.customer != null &&
        !cart.customer!.isConfrere) {
      final today = DateUtils.dateOnly(DateTime.now());
      dueDate = await showDatePicker(
        context: context,
        helpText: 'Échéance du crédit de ${formatDA(estimate.totalTtc - kept)}',
        initialDate: today.add(const Duration(days: 30)),
        firstDate: today,
        lastDate: today.add(const Duration(days: 730)),
      );
      if (dueDate == null || !mounted) return;
    }
    setState(() => _busy = true);
    try {
      final outcome = await ref
          .read(salesActionsProvider)
          .checkout(
            kept,
            expectedTotalTtc: estimate.totalTtc,
            dueDate: dueDate,
          );
      if (!mounted) return;
      final change = received - kept;
      switch (outcome) {
        case Applied(value: final sale):
          ref.invalidate(stockByProductProvider);
          // Confirmation animée (2026-10-29) : la vente est bien passée.
          showFeedbackBurst(
            context,
            FeedbackKind.success,
            'Vente encaissée',
            detail: formatDA(estimate.totalTtc),
          );
          await _showTicket(sale, change: change);
        case Queued():
          showFeedbackBurst(
            context,
            FeedbackKind.pending,
            'Enregistrée hors ligne',
          );
          await _showQueued(
            total: estimate.totalTtc,
            kept: kept,
            change: change,
          );
      }
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
      if (mounted) {
        showFeedbackBurst(context, FeedbackKind.error, 'Vente refusée');
        _snack(context, error.userMessage);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Vente mise en file hors-ligne : PAS un ticket — le serveur n'a encore rien
  /// jugé (stock, prix, caisse). Affichée « en attente », jamais comme faite
  /// (docs/context.md §6) ; un refus apparaîtra dans le panneau de synchro.
  Future<void> _showQueued({
    required int total,
    required int kept,
    required int change,
  }) {
    return showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Vente en attente de synchronisation'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Pas de connexion : la vente est enregistrée sur cet appareil, '
                'pas encore confirmée par le serveur. Le ticket officiel sera '
                'disponible après la synchronisation.',
              ),
              const Divider(),
              Text('Total TTC : ${formatDA(total)}'),
              Text('Encaissé : ${formatDA(kept)}'),
              if (change > 0)
                Text(
                  'Monnaie à rendre : ${formatDA(change)}',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
            ],
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Compris'),
          ),
        ],
      ),
    );
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

  /// Champ de recherche / douchette / caméra, commun aux deux dispositions.
  InputDecoration _searchDecoration(List<Product> products) => InputDecoration(
    prefixIcon: const Icon(LucideIcons.scanBarcode, size: 20),
    hintText: 'Scanner un code-barres ou chercher un produit (F2)',
    suffixIcon: CameraScanButton(onCode: (code) => _scan(code, products)),
  );

  @override
  Widget build(BuildContext context) {
    final products = ref.watch(activeProductsProvider).value ?? const [];
    // Stock du magasin gardé chargé : il juge les ajouts et l'encaissement.
    ref.watch(stockByProductProvider);
    if (!widget.rights.canSell) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(widget.margin, 8, widget.margin, 8),
            child: widget.tabs,
          ),
          const Expanded(
            child: ScreenStateView(
              status: ScreenStatus.empty,
              title: 'Vente réservée aux vendeurs',
            ),
          ),
        ],
      );
    }
    final sync = ref.watch(catalogSyncProvider);
    // Catalogue local encore vide (poste neuf) : on dit pourquoi, au lieu de
    // laisser croire qu'aucun produit n'existe.
    final catalogAlert = products.isNotEmpty
        ? null
        : AmpereInlineAlert(
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
          );

    // Caisse (2026-10-06) : catalogue en tuiles à gauche, ticket à droite —
    // dès que la place le permet ; sinon le ticket seul, payer en bas.
    return LayoutBuilder(
      builder: (context, box) => box.maxWidth >= 860
          ? _wideLayout(products, catalogAlert)
          : _narrowLayout(products, catalogAlert),
    );
  }

  Widget _wideLayout(List<Product> products, Widget? catalogAlert) {
    final m = widget.margin;
    // Caisse au clavier : F2 cherche / scanne, F9 encaisse.
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.f2): () =>
            _searchFocus.requestFocus(),
        const SingleActivator(LogicalKeyboardKey.f9): _payShortcut,
      },
      child: _wideBody(products, catalogAlert, m),
    );
  }

  /// F9 : le même geste que le bouton principal, s'il est actif.
  void _payShortcut() {
    final estimate = ref.read(cartEstimateProvider);
    final cart = ref.read(cartProvider);
    if (_busy ||
        estimate.blocked ||
        cart.isEmpty ||
        cart.quote != null ||
        _shortages(cart).isNotEmpty) {
      return;
    }
    if (cart.buyer == null) {
      _chooseBuyer();
      return;
    }
    final cash = ref.read(currentCashSessionProvider);
    if (cash.hasValue && cash.value == null && cart.customer == null) {
      if (widget.rights.canManageCash) _openCashFlow(context, ref);
      return;
    }
    _checkout(estimate);
  }

  Widget _wideBody(List<Product> products, Widget? catalogAlert, double m) {
    final colors = AmpereColors.of(context);
    // Caisse en grand (2026-10-12) : le catalogue à gauche, le TICKET occupe
    // toute la hauteur à droite, collé au bord — rien ne se perd en cadres.
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Padding(
            padding: EdgeInsets.fromLTRB(m + 8, 16, m + 8, m + 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                widget.tabs,
                const SizedBox(height: 18),
                ?catalogAlert,
                if (catalogAlert != null) const SizedBox(height: 12),
                TextField(
                  controller: _search,
                  focusNode: _searchFocus,
                  autofocus: true,
                  autocorrect: false,
                  style: AmpereType.input,
                  decoration: _searchDecoration(products),
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (value) => _submitSearch(value, products),
                ),
                const SizedBox(height: 16),
                _CategoryChips(
                  products: products,
                  selected: _categoryId,
                  onSelect: (id) => setState(() => _categoryId = id),
                ),
                const SizedBox(height: 16),
                Expanded(
                  child: _ProductGrid(
                    products: _categoryId == null
                        ? products
                        : [
                            for (final p in products)
                              if (p.categoryId == _categoryId) p,
                          ],
                    query: _search.text,
                    onPick: (p) {
                      _add(p);
                      _searchFocus.requestFocus();
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
        SizedBox(
          width: (MediaQuery.sizeOf(context).width * 0.38).clamp(440.0, 620.0),
          // Séparations NOIRES, de l'épaisseur du cadre de l'écran
          // (essai demandé par MEDMEDBEN le 2026-10-29) : le ticket et le
          // paiement sont des panneaux arrondis découpés dans le cadre.
          child: ColoredBox(
            color: Colors.black,
            child: Padding(
              padding: const EdgeInsets.only(left: ScreenFrame.width),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: ClipRRect(
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(16),
                        bottomLeft: Radius.circular(16),
                        bottomRight: Radius.circular(16),
                      ),
                      child: ColoredBox(
                        color: colors.surface,
                        child: ListView(
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                          children: _ticketBody(),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: ScreenFrame.width),
                  ClipRRect(
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(16),
                      topRight: Radius.circular(16),
                      bottomLeft: Radius.circular(16),
                    ),
                    child: ColoredBox(
                      color: colors.surface,
                      child: _payPanel(),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _narrowLayout(List<Product> products, Widget? catalogAlert) {
    final m = widget.margin;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: ListView(
            padding: EdgeInsets.fromLTRB(m, 8, m, 16),
            children: [
              widget.tabs,
              const SizedBox(height: 12),
              ?catalogAlert,
              if (catalogAlert != null) const SizedBox(height: 12),
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
                  _add(p);
                  _search.clear();
                },
                fieldViewBuilder: (context, controller, focus, _) {
                  // Le champ de l'Autocomplete sert aussi à la douchette.
                  return TextField(
                    controller: controller,
                    focusNode: focus,
                    autofocus: true,
                    autocorrect: false,
                    style: AmpereType.input,
                    decoration: _searchDecoration(products),
                    onSubmitted: (value) {
                      _scan(value, products);
                      controller.clear();
                    },
                  );
                },
              ),
              const SizedBox(height: 14),
              ..._ticketBody(),
            ],
          ),
        ),
        if (!ref.watch(cartProvider).isEmpty)
          DecoratedBox(
            decoration: BoxDecoration(
              color: AmpereColors.of(context).surface,
              border: Border(
                top: BorderSide(color: AmpereColors.of(context).line),
              ),
            ),
            child: _payPanel(compact: true),
          ),
      ],
    );
  }

  /// « Entrée » dans la recherche : code-barres exact, sinon l'UNIQUE produit
  /// trouvé (on tape « 3G2 », Entrée, c'est ajouté).
  void _submitSearch(String value, List<Product> products) {
    if (productForBarcode(products, value.trim()) == null) {
      final found = _searchProducts(products, value);
      if (found.length == 1) {
        _add(found.single);
        _search.clear();
        _searchFocus.requestFocus();
        setState(() {});
        return;
      }
    }
    _scan(value, products);
    setState(() {});
  }

  /// Le ticket : caisse, client, lignes.
  List<Widget> _ticketBody() {
    final colors = AmpereColors.of(context);
    final cart = ref.watch(cartProvider);
    final estimate = ref.watch(cartEstimateProvider);
    final articles = cart.lines.length;
    return [
      if (widget.rights.canManageCash) ...[
        const _CashBar(),
        const SizedBox(height: 10),
      ],
      Row(
        children: [
          Icon(LucideIcons.receipt, size: 15, color: colors.ink2),
          const SizedBox(width: 8),
          Text(
            'Ticket',
            style: AmpereType.bodyStrong.copyWith(color: colors.ink),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              articles > 0
                  ? '$articles article(s) · ${formatDate(DateTime.now())}'
                  : formatDate(DateTime.now()),
              textAlign: TextAlign.end,
              overflow: TextOverflow.ellipsis,
              style: AmpereType.meta.copyWith(color: colors.ink3),
            ),
          ),
        ],
      ),
      const SizedBox(height: 8),
      Divider(height: 1, color: colors.line),
      const SizedBox(height: 10),
      BuyerBar(
        withConfreres: widget.rights.canSeeConfreres,
        withSuppliers:
            widget.rights.canSeeConfreres && widget.rights.canWriteCustomers,
      ),
      if (cart.quote case final quote?) ...[
        const SizedBox(height: 10),
        AmpereInlineAlert(
          tone: StatusTone.info,
          message:
              'Modification du devis ${quote.number} : le panier remplacera '
              'ses lignes. « Vider » abandonne la modification.',
        ),
      ],
      const SizedBox(height: 10),
      if (cart.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 36),
          child: Column(
            children: [
              Icon(LucideIcons.shoppingCart, size: 40, color: colors.ink3),
              const SizedBox(height: 10),
              Text(
                'Panier vide',
                style: AmpereType.rowTitle.copyWith(color: colors.ink2),
              ),
              const SizedBox(height: 4),
              Text(
                'Scannez ou touchez un produit pour commencer.',
                textAlign: TextAlign.center,
                style: AmpereType.meta.copyWith(color: colors.ink3),
              ),
            ],
          ),
        )
      else
        for (final line in cart.lines)
          // Une ligne qui ARRIVE glisse en place (2026-10-29) ; les autres
          // ne bougent pas (clé par produit).
          _AppearIn(
            key: ValueKey('ligne-${line.product.id}'),
            child: _CartLineRow(
              line: line,
              missingPrice: estimate.missingPrices.contains(line.product),
              invalidDiscount: estimate.invalidDiscounts.contains(line.product),
              totalHt: estimate.lineTotalsHt[line.product.id],
              unitPriceHt: estimate.unitPricesHt[line.product.id],
              tariffPriceHt: estimate.tariffPricesHt[line.product.id],
              canDiscount: widget.rights.canDiscount,
            ),
          ),
    ];
  }

  /// Zone de paiement : afficheur du total, alertes, gros bouton Encaisser.
  Widget _payPanel({bool compact = false}) {
    final cart = ref.watch(cartProvider);
    final estimate = ref.watch(cartEstimateProvider);
    final cashState = ref.watch(currentCashSessionProvider);
    // Hors ligne, la caisse est INCONNUE (pas « fermée ») : pas d'alerte, le
    // serveur vérifiera à la synchronisation.
    final noCash = cashState.hasValue && cashState.value == null;
    final blocked = _busy || estimate.blocked || cart.isEmpty;
    final shortages = _shortages(cart);
    // Acheteur à choisir à CHAQUE vente (décision du 2026-10-12).
    final noBuyer = cart.buyer == null && cart.quote == null;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 10, 16, compact ? 10 : 14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _TotalDisplay(
            total: estimate.totalTtc,
            articles: cart.lines.length,
            compact: compact,
          ),
          if (!cart.isEmpty &&
              cart.quote == null &&
              (cart.discountHt > 0 || widget.rights.canSeeProfit))
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                children: [
                  if (cart.discountHt > 0)
                    InputChip(
                      avatar: Icon(
                        LucideIcons.percent,
                        size: 14,
                        color: AmpereColors.of(context).warn,
                      ),
                      label: Text(
                        'Remise −${formatDA(cart.discountHt)}',
                        style: AmpereType.bodyStrong.copyWith(
                          color: AmpereColors.of(context).warn,
                        ),
                      ),
                      deleteButtonTooltipMessage: 'Retirer la remise',
                      onPressed: _busy ? null : () => _globalDiscount(estimate),
                      onDeleted: () =>
                          ref.read(cartProvider.notifier).setGlobalDiscount(0),
                    ),
                  const Spacer(),
                  if (widget.rights.canSeeProfit)
                    if (estimate.profitHt case final profit?)
                      Text(
                        'Profit ${formatDA(profit)}',
                        style: AmpereType.bodyStrong.copyWith(
                          color: profit >= 0
                              ? AmpereColors.of(context).ok
                              : AmpereColors.of(context).error,
                        ),
                      ),
                ],
              ),
            ),
          if (estimate.invalidGlobalDiscount) ...[
            const SizedBox(height: 6),
            AmpereInlineAlert(
              message:
                  'La remise sur facture dépasse la marge '
                  '(${formatDA(estimate.maxDiscountHt)} au plus) : réduisez-la.',
            ),
          ],
          if (estimate.missingPrices.isNotEmpty) ...[
            const SizedBox(height: 10),
            const AmpereInlineAlert(
              message:
                  'Certains produits n’ont pas de prix pour ce tarif : '
                  'la vente sera refusée.',
            ),
          ],
          if (estimate.invalidDiscounts.isNotEmpty) ...[
            const SizedBox(height: 10),
            const AmpereInlineAlert(
              message:
                  'Une remise dépasse désormais ce que sa ligne permet (elle '
                  'ferait vendre sous le coût) : corrigez-la avant d’encaisser.',
            ),
          ],
          if (shortages.isNotEmpty) ...[
            const SizedBox(height: 10),
            AmpereInlineAlert(
              icon: LucideIcons.packageX,
              message:
                  'Pas assez au magasin : '
                  '${shortages.map((s) => '${s.$1.name} (reste ${formatQuantity(s.$2)} ${s.$1.unit.short})').join(', ')}'
                  '. Retirez-le, baissez la quantité ou faites-le venir du '
                  'dépôt — sinon la vente sera refusée.',
            ),
          ],
          const SizedBox(height: 8),
          // Les gestes du panier en boutons étiquetés et colorés (demande
          // MEDMEDBEN du 2026-10-13 : « remise, devis… dans un bouton clair »).
          if (!cart.isEmpty) ...[
            Row(
              children: [
                if (cart.quote == null) ...[
                  Expanded(
                    child: _CartAction(
                      icon: LucideIcons.percent,
                      label: cart.discountHt > 0 ? 'Changer remise' : 'Remise',
                      color: AmpereColors.of(context).warn,
                      onPressed: _busy ? null : () => _globalDiscount(estimate),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: _CartAction(
                      icon: LucideIcons.fileText,
                      label: 'Devis',
                      color: AmpereColors.of(context).info,
                      onPressed: blocked ? null : _makeQuote,
                    ),
                  ),
                  const SizedBox(width: 6),
                ],
                Expanded(
                  child: _CartAction(
                    icon: LucideIcons.trash2,
                    label: 'Vider',
                    color: AmpereColors.of(context).error,
                    onPressed: _busy
                        ? null
                        : () => ref.read(cartProvider.notifier).clear(),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
          ],
          Row(
            children: [
              Expanded(
                child: noBuyer
                    ? _PayButton(
                        icon: LucideIcons.userRoundSearch,
                        label: 'Choisir l’acheteur',
                        height: 42,
                        tone: AmpereColors.of(context).accent,
                        onPressed: cart.isEmpty ? null : _chooseBuyer,
                      )
                    : (noCash && cart.customer == null && cart.quote == null)
                    ?
                      // Une caisse ne vit qu'un jour : avant la première vente
                      // espèces, on compte le tiroir (décision du 2026-10-08).
                      _PayButton(
                        icon: LucideIcons.lockOpen,
                        label: 'Ouvrir la caisse pour encaisser',
                        height: 42,
                        tone: AmpereColors.of(context).warn,
                        onPressed: widget.rights.canManageCash
                            ? () => _openCashFlow(context, ref)
                            : null,
                      )
                    : cart.quote != null
                    ?
                      // Un devis en cours de modification ne s'encaisse pas ici : il se
                      // met à jour, puis suit son cycle (envoi, acceptation, conversion).
                      _PayButton(
                        icon: LucideIcons.fileText,
                        label: 'Mettre à jour le devis ${cart.quote!.number}',
                        height: 42,
                        onPressed: blocked ? null : _updateQuote,
                      )
                    : _PayButton(
                        icon: LucideIcons.banknote,
                        label: 'Encaisser ${formatDA(estimate.totalTtc)}',
                        shortcut: compact ? null : 'F9',
                        height: 42,
                        onPressed: blocked || shortages.isNotEmpty
                            ? null
                            : () => _checkout(estimate),
                      ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Afficheur de caisse : le montant à payer, en grand, comme sur un terminal.
class _TotalDisplay extends StatelessWidget {
  const _TotalDisplay({
    required this.total,
    required this.articles,
    this.compact = false,
  });

  final int total;
  final int articles;

  /// Téléphone : une seule ligne, « TOTAL » à gauche, le montant à droite.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    // Le montant défile vers le haut à chaque changement (2026-10-29).
    final amount = AnimatedSwitcher(
      duration: const Duration(milliseconds: 260),
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: SlideTransition(
          position: Tween(
            begin: const Offset(0, 0.4),
            end: Offset.zero,
          ).animate(animation),
          child: child,
        ),
      ),
      child: Text(
        formatDA(total),
        key: ValueKey(total),
        style: AmpereType.numericHero.copyWith(
          fontSize: compact ? 24 : 26,
          color: colors.ink,
        ),
      ),
    );
    // Sobre (maquette du 2026-10-26) : un encadré gris clair, sans halo.
    final screen = BoxDecoration(
      borderRadius: BorderRadius.circular(12),
      color: colors.surface2,
      border: Border.all(color: colors.line),
    );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: screen,
      child: Row(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                compact ? 'TOTAL' : 'TOTAL À PAYER',
                style: AmpereType.label.copyWith(
                  color: colors.ink3,
                  letterSpacing: 1.2,
                ),
              ),
              Text(
                '$articles article(s)',
                style: AmpereType.meta.copyWith(color: colors.ink3),
              ),
            ],
          ),
          const SizedBox(width: 12),
          Expanded(
            child: FittedBox(
              alignment: Alignment.centerRight,
              fit: BoxFit.scaleDown,
              child: amount,
            ),
          ),
        ],
      ),
    );
  }
}

/// Le bouton qui encaisse : grand, vert, impossible à manquer.
class _PayButton extends StatelessWidget {
  const _PayButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.height = 60,
    this.tone,
    this.shortcut,
  });

  /// Touche du poste qui fait le même geste (affichée en petit).
  final String? shortcut;

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final double height;

  /// Couleur du dégradé ; par défaut le vert « encaisser ».
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    // Plein, sans dégradé ni ombre (maquette du 2026-10-26) : noir en clair.
    final tone = this.tone ?? colors.accent;
    final enabled = onPressed != null;
    final radius = BorderRadius.circular(10);
    return SizedBox(
      height: height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          color: enabled ? tone : colors.surface3,
        ),
        child: FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: Colors.transparent,
            disabledBackgroundColor: Colors.transparent,
            shadowColor: Colors.transparent,
            foregroundColor: colors.onAccent,
            disabledForegroundColor: colors.ink3,
            textStyle: AmpereType.bodyStrong.copyWith(fontSize: 14),
            shape: RoundedRectangleBorder(borderRadius: radius),
          ),
          onPressed: onPressed,
          icon: Icon(icon, size: 17),
          label: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
              if (shortcut case final key?) ...[
                const SizedBox(width: 10),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: colors.onAccent.withValues(alpha: 0.5),
                    ),
                  ),
                  child: Text(key, style: AmpereType.label),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Filtres de la grille : « Tout » puis les catégories qui ont des produits.
class _CategoryChips extends ConsumerWidget {
  const _CategoryChips({
    required this.products,
    required this.selected,
    required this.onSelect,
  });

  final List<Product> products;
  final String? selected;
  final ValueChanged<String?> onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final used = {for (final p in products) ?p.categoryId};
    final categories = [
      for (final c in ref.watch(categoriesProvider).value ?? const [])
        if (used.contains(c.id)) c,
    ]..sort((a, b) => a.name.compareTo(b.name));
    if (categories.isEmpty) return const SizedBox.shrink();
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final (id, label) in [
            (null, 'Tout'),
            for (final c in categories) (c.id, c.name),
          ])
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(label),
                selected: selected == id,
                showCheckmark: false,
                onSelected: (_) => onSelect(id),
              ),
            ),
        ],
      ),
    );
  }
}

/// Catalogue de la caisse : des tuiles à toucher (nom, prix, déjà au panier).
class _ProductGrid extends ConsumerWidget {
  const _ProductGrid({
    required this.products,
    required this.query,
    required this.onPick,
  });

  final List<Product> products;
  final String query;
  final ValueChanged<Product> onPick;

  /// Au-delà, on demande d'affiner : une grille de 2 000 tuiles ne se lit pas.
  static const _shown = 120;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = AmpereColors.of(context);
    final tiers = ref.watch(priceTiersProvider).value ?? const <PriceTier>[];
    final defaultTier = tiers.where((t) => t.isDefault).firstOrNull?.id;
    final inCart = {
      for (final l in ref.watch(cartProvider).lines) l.product.id: l.quantity,
    };
    // Stock du MAGASIN (lu en ligne) : la couleur de la tuile dit s'il y en a.
    // Inconnu (hors ligne) : pas de couleur, jamais un état inventé.
    final stock = ref.watch(stockByProductProvider).value;
    final store = (ref.watch(locationsProvider).value ?? const [])
        .where((l) => l.type == 'MAGASIN')
        .firstOrNull;
    Quantity? atStore(Product p) => stock == null || store == null
        ? null
        : stock[p.id]?.at(store.id) ?? Quantity.zero;
    final found = query.trim().isEmpty
        ? products
        : _searchProducts(products, query);
    if (found.isEmpty) {
      return Center(
        child: Text(
          'Aucun produit ne correspond à « ${query.trim()} ».',
          style: AmpereType.body.copyWith(color: colors.ink3),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (stock != null && store != null) ...[
          Wrap(
            spacing: 16,
            children: [
              for (final (tone, label) in [
                (colors.ok, 'En stock'),
                (colors.warn, 'Stock bas'),
                (colors.error, 'Rupture'),
              ])
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        color: tone,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      label,
                      style: AmpereType.meta.copyWith(color: colors.ink3),
                    ),
                  ],
                ),
            ],
          ),
          const SizedBox(height: 14),
        ],
        Expanded(
          child: GridView.builder(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              // Tuiles compactes, façon logiciel de caisse (2026-10-26) :
              // l'essentiel (nom, stock, prix), plus d'espace entre elles.
              maxCrossAxisExtent: 190,
              mainAxisExtent: 138,
              crossAxisSpacing: 14,
              mainAxisSpacing: 14,
            ),
            itemCount: found.length.clamp(0, _shown),
            itemBuilder: (context, i) {
              final p = found[i];
              return _ProductTile(
                product: p,
                stock: atStore(p),
                price: p.salePriceHt(defaultTier),
                inCart: inCart[p.id],
                onTap: () => onPick(p),
              );
            },
          ),
        ),
        if (found.length > _shown)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              '${found.length - _shown} autre(s) produit(s) : affinez la '
              'recherche.',
              style: AmpereType.meta.copyWith(color: colors.ink3),
            ),
          ),
      ],
    );
  }
}

class _ProductTile extends StatelessWidget {
  const _ProductTile({
    required this.product,
    required this.stock,
    required this.price,
    required this.inCart,
    required this.onTap,
  });

  final Product product;
  final int? price;
  final Quantity? inCart;

  /// Stock au magasin ; `null` = inconnu (hors ligne).
  final Quantity? stock;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    final picked = inCart != null;
    // La couleur DIT quelque chose : vert en stock, orange sous le seuil,
    // rouge en rupture (le serveur refusera la vente, sauf backorder).
    final level = stock;
    final tone = level == null
        ? colors.ink3
        : level <= Quantity.zero
        ? colors.error
        : level <= product.minThreshold
        ? colors.warn
        : colors.ok;
    final stockLabel = level == null
        ? product.sku
        : level <= Quantity.zero
        ? 'Rupture'
        : 'Stock ${formatQuantity(level)} ${product.unit.short}';
    // Rebond quand on l'ajoute au panier (2026-10-29) : le geste est vu.
    return TweenAnimationBuilder<double>(
      key: ValueKey('tuile-${inCart?.toString() ?? '0'}'),
      tween: Tween(begin: picked ? 0.9 : 1, end: 1),
      duration: const Duration(milliseconds: 420),
      curve: Curves.elasticOut,
      builder: (context, scale, child) =>
          Transform.scale(scale: scale, child: child),
      child: Material(
        color: colors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(
            color: picked ? colors.accent : colors.line,
            width: picked ? 1.5 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ProductThumbnail(product: product, size: 32),
                    const Spacer(),
                    if (picked)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: colors.accent,
                          borderRadius: BorderRadius.circular(99),
                        ),
                        child: Text(
                          formatQuantity(inCart!),
                          style: AmpereType.label.copyWith(
                            color: colors.onAccent,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: Text(
                    product.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AmpereType.bodyStrong.copyWith(color: colors.ink),
                  ),
                ),
                Row(
                  children: [
                    // Le stock dit sa couleur par un simple point.
                    Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        color: tone,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        stockLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AmpereType.meta.copyWith(color: colors.ink3),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  price == null
                      ? 'Prix non fixé'
                      : '${formatDA(price!)} / ${product.unit.short}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AmpereType.bodyStrong.copyWith(
                    fontSize: 14,
                    color: price == null ? colors.error : colors.ink,
                    fontFeatures: AmpereType.tabular,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Recherche de la caisse : nom, référence ou code-barres, sans accents.
List<Product> _searchProducts(List<Product> products, String query) {
  final term = foldForSearch(query);
  if (term.isEmpty) return products;
  return [
    for (final p in products)
      if (foldForSearch('${p.name} ${p.sku} ${p.barcode}').contains(term)) p,
  ];
}

class _CartLineRow extends ConsumerWidget {
  const _CartLineRow({
    required this.line,
    required this.missingPrice,
    this.totalHt,
    this.unitPriceHt,
    this.tariffPriceHt,
    this.canDiscount = false,
    this.invalidDiscount = false,
  });

  final bool canDiscount;
  final bool invalidDiscount;
  final CartLine line;
  final bool missingPrice;
  final int? totalHt;
  final int? unitPriceHt;
  final int? tariffPriceHt;

  /// Quantité saisie au clavier (décimale, ex. 12,5 m). 0 retire la ligne.
  Future<void> _editQuantity(BuildContext context, WidgetRef ref) async {
    final unit = line.product.unit.short;
    final values = await askFields(
      context,
      title: 'Quantité — ${line.product.name}',
      confirm: 'Valider',
      fields: [
        (
          key: 'quantity',
          label: 'Quantité ($unit)',
          initial: formatQuantity(line.quantity),
        ),
      ],
    );
    final raw = values?['quantity'];
    if (raw == null || !context.mounted) return;
    final quantity = parseQuantity(raw);
    if (quantity == null || quantity < Quantity.zero) {
      _snack(context, 'Quantité invalide : un nombre, ex. 12,5');
      return;
    }
    ref.read(cartProvider.notifier).setQuantity(line.product.id, quantity);
  }

  /// Prix modifiable en vente (décision MEDMEDBEN 2026-09-22), jamais sous le
  /// plancher : dernier prix d'achat, sinon tarif. Le serveur revérifie.
  Future<void> _editPrice(BuildContext context, WidgetRef ref) async {
    final floor = priceFloor(line.product);
    if (floor == null) {
      _snack(
        context,
        'Aucun prix de vente pour « ${line.product.name} » : '
        'l’administrateur doit le définir',
      );
      return;
    }
    final value = await askAmount(
      context,
      title: 'Prix de « ${line.product.name} »',
      label: 'Prix unitaire',
      confirm: 'Appliquer',
      initial: unitPriceHt,
      help: [
        if (tariffPriceHt != null) 'Tarif : ${formatDA(tariffPriceHt!)}',
        // Le coût d'achat guide la baisse de prix (2026-10-05).
        if (line.product.lastPurchasePriceHt case final cost?)
          'prix d’achat : ${formatDA(cost)}',
        'minimum : ${formatDA(floor)}',
      ].join(' · '),
    );
    if (value == null || !context.mounted) return;
    if (value < floor) {
      _snack(
        context,
        'Prix trop bas : minimum ${formatDA(floor)} '
        '(${(line.product.lastPurchasePriceHt ?? 0) > 0 ? 'prix d’achat' : 'tarif'})',
      );
      return;
    }
    ref.read(cartProvider.notifier).setPrice(line.product.id, value);
  }

  /// Remise HT sur la ligne (ADMIN). Mêmes bornes que le serveur : jamais plus
  /// que la ligne, jamais un net sous le plancher (coût) × quantité.
  Future<void> _editDiscount(BuildContext context, WidgetRef ref) async {
    final price = unitPriceHt;
    if (price == null) return;
    final gross = lineGrossHt(price, line.quantity);
    final maxDiscount = maxLineDiscountHt(line.product, price, line.quantity);
    // En DA ou en % (2026-10-12) ; jamais sous le coût (bouton grisé).
    final value = await askDiscount(
      context,
      title: 'Remise sur « ${line.product.name} »',
      baseHt: gross,
      maxHt: maxDiscount,
      initialHt: line.discountHt,
    );
    if (value == null || !context.mounted) return;
    ref.read(cartProvider.notifier).setDiscount(line.product.id, value);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = AmpereColors.of(context);
    final cart = ref.read(cartProvider.notifier);
    // Une seule bande par ligne (demande MEDMEDBEN du 2026-10-26) : nom et
    // prix à gauche ; quantité, total et gestes à droite, en petit.
    Widget tool(
      IconData icon,
      String tip,
      VoidCallback onPressed, {
      Color? color,
    }) => IconButton(
      tooltip: tip,
      style: IconButton.styleFrom(
        padding: EdgeInsets.zero,
        minimumSize: const Size(26, 26),
        fixedSize: const Size(26, 26),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      iconSize: 14,
      icon: Icon(icon, color: color ?? colors.ink2),
      onPressed: onPressed,
    );
    final badges = [
      if (missingPrice)
        const AmpereBadge(label: 'Prix non fixé', tone: StatusTone.error)
      else if (unitPriceHt != tariffPriceHt)
        const AmpereBadge(label: 'Prix modifié', tone: StatusTone.warn),
      if (invalidDiscount)
        AmpereBadge(
          label: 'Remise ${formatDA(line.discountHt)} trop forte — à corriger',
          tone: StatusTone.error,
        )
      else if (line.discountHt > 0)
        Text(
          'Remise ${formatDA(line.discountHt)}',
          style: AmpereType.meta.copyWith(color: colors.warn),
        ),
    ];
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 7),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.lineSoft)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  line.product.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AmpereType.bodyStrong.copyWith(color: colors.ink),
                ),
                Text(
                  [
                    if (unitPriceHt != null)
                      '${formatDA(unitPriceHt!)} / ${line.product.unit.short}',
                    // Prix d'achat visible (2026-10-05) : jusqu'où baisser.
                    if (line.product.lastPurchasePriceHt case final cost?)
                      'achat ${formatDA(cost)}',
                    line.product.sku,
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AmpereType.meta.copyWith(color: colors.ink3),
                ),
                if (badges.isNotEmpty)
                  Wrap(spacing: 4, runSpacing: 2, children: badges),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // Quantité : − 2 pce +, petite pastille bordée.
          Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: colors.line),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                tool(
                  LucideIcons.minus,
                  'Moins',
                  () => cart.setQuantity(
                    line.product.id,
                    line.quantity - Quantity.one,
                  ),
                ),
                // Toucher la quantité la SAISIT (2026-10-12).
                InkWell(
                  onTap: () => _editQuantity(context, ref),
                  child: Tooltip(
                    message: 'Saisir la quantité',
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minWidth: 44),
                      child: Text(
                        '${formatQuantity(line.quantity)} ${line.product.unit.short}',
                        textAlign: TextAlign.center,
                        style: AmpereType.bodyStrong.copyWith(
                          color: colors.ink,
                          fontFeatures: AmpereType.tabular,
                          decoration: TextDecoration.underline,
                          decorationStyle: TextDecorationStyle.dotted,
                        ),
                      ),
                    ),
                  ),
                ),
                tool(LucideIcons.plus, 'Plus', () => cart.add(line.product)),
              ],
            ),
          ),
          SizedBox(
            width: 92,
            child: Text(
              totalHt == null ? '—' : formatDA(totalHt!),
              textAlign: TextAlign.end,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AmpereType.bodyStrong.copyWith(
                color: colors.ink,
                fontFeatures: AmpereType.tabular,
              ),
            ),
          ),
          const SizedBox(width: 4),
          tool(
            LucideIcons.pencil,
            'Modifier le prix',
            () => _editPrice(context, ref),
          ),
          if (canDiscount && !missingPrice)
            tool(
              LucideIcons.percent,
              'Remise',
              () => _editDiscount(context, ref),
            ),
          tool(
            LucideIcons.trash2,
            'Retirer',
            () => cart.setQuantity(line.product.id, Quantity.zero),
            color: colors.error,
          ),
        ],
      ),
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
  const _CustomersSection({
    required this.margin,
    required this.rights,
    required this.onSell,
  });

  final double margin;
  final SalesRights rights;

  /// Ouvre la vente avec ce client au panier.
  final ValueChanged<Customer> onSell;

  @override
  ConsumerState<_CustomersSection> createState() => _CustomersSectionState();
}

class _CustomersSectionState extends ConsumerState<_CustomersSection> {
  String _query = '';

  /// Fiche complète (P1 bis n°21e) : même formulaire en création et en
  /// modification ; tarif et plafond seulement pour l'administrateur.
  Future<void> _create([Customer? existing]) => openFormPanel<void>(
    context,
    CustomerForm(
      existing: existing,
      canManageTerms: widget.rights.canManageCustomerTerms,
      canChangeActive: widget.rights.canDeleteCustomers,
    ),
  );

  Future<void> _pay(Customer customer) async {
    final amount = await askAmount(
      context,
      title: 'Règlement de ${customer.name}',
      label: 'Espèces reçues',
      confirm: 'Encaisser',
      initial: customer.balanceDue,
      help: 'Dette : ${formatDA(customer.balanceDue)}',
    );
    if (amount == null || amount == 0 || !mounted) return;
    try {
      // Même clé à chaque essai de ce règlement, dialogue rouvert compris ;
      // sans réseau, il part dans la file (même clé).
      final outcome = await ref
          .read(salesActionsProvider)
          .payCustomer(customer.id, amount);
      if (mounted) {
        _snack(
          context,
          outcome is Queued
              ? 'Règlement de ${formatDA(amount)} enregistré sur cet appareil — '
                    'en attente de synchronisation.'
              : 'Règlement de ${formatDA(amount)} encaissé.',
        );
      }
    } on ApiException catch (error) {
      if (mounted) _snack(context, error.userMessage);
    }
  }

  /// « Supprimer » = retirer des listes : ventes et règlements restent ; le
  /// serveur refuse tant qu'il reste une dette (il le dit).
  Future<void> _delete(Customer customer) async {
    final confirmed = await showAmpereConfirmDialog(
      context,
      title: 'Supprimer « ${customer.name} » ?',
      body:
          'Le client disparaît des listes et de la vente. Ses ventes et ses '
          'règlements restent dans l’historique. Impossible tant qu’il a une '
          'dette.',
      confirmLabel: 'Supprimer',
    );
    if (!confirmed || !mounted) return;
    try {
      await ref.read(salesActionsProvider).saveCustomer(customer.id, {
        'isActive': false,
      });
      if (mounted) _snack(context, '${customer.name} supprimé des clients.');
    } on ApiException catch (error) {
      if (mounted) _snack(context, error.userMessage);
    }
  }

  Future<void> _openCustomer(Customer customer) async {
    final rights = widget.rights;
    // Fiche CONTACT (2026-10-06) : coordonnées, compte, actions, supprimer.
    final action = await showContactProfile(
      context,
      name: customer.name,
      kind: 'Client',
      phone: customer.phone,
      email: customer.email,
      address: customer.address,
      notes: customer.notes,
      figures: [
        if (customer.totalPurchased case final bought?)
          (
            label: 'Total acheté',
            value: formatDA(bought),
            tone: StatusTone.neutral,
          ),
        if (customer.totalPaid case final paid?)
          (label: 'Payé', value: formatDA(paid), tone: StatusTone.neutral),
        (
          label: 'Reste dû',
          value: formatDA(customer.balanceDue),
          tone: customer.balanceDue > 0 ? StatusTone.warn : StatusTone.ok,
        ),
        if (customer.overdueAmount > 0)
          (
            label: 'En retard',
            value: formatDA(customer.overdueAmount),
            tone: StatusTone.error,
          ),
        if (customer.creditLimit > 0)
          (
            label: 'Plafond de crédit',
            value: formatDA(customer.creditLimit),
            tone: StatusTone.neutral,
          ),
      ],
      actions: [
        if (rights.canTakePayments && customer.balanceDue > 0)
          (
            icon: LucideIcons.banknote,
            label: 'Encaisser un règlement',
            value: 'pay',
          ),
        if (rights.canSell)
          (
            icon: LucideIcons.shoppingBag,
            label: 'Historique des achats',
            value: 'sales',
          ),
        (
          icon: LucideIcons.history,
          label: 'Historique des règlements',
          value: 'history',
        ),
        if (rights.canReadStatements)
          (
            icon: LucideIcons.fileText,
            label: 'Relevé de compte (PDF)',
            value: 'statement',
          ),
        if (rights.canWriteCustomers)
          (icon: LucideIcons.pencil, label: 'Modifier la fiche', value: 'edit'),
      ],
      canDelete: rights.canDeleteCustomers,
    );
    if (!mounted || action == null) return;
    if (action == contactDeleteAction) return _delete(customer);
    if (action == 'pay') return _pay(customer);
    if (action == 'statement') {
      // P1 bis n°21n : enregistré sur ce poste, comme les autres exports.
      try {
        final path = await ref.read(saveExportProvider)(
          await ref
              .read(salesApiProvider)
              .customerStatement(customer.id, ExportFormat.pdf),
        );
        if (mounted) _snack(context, 'Enregistré sur ce poste : $path');
      } on ApiException catch (error) {
        if (mounted) _snack(context, error.userMessage);
      } on Exception {
        if (mounted) {
          _snack(context, 'Le relevé n’a pas pu être enregistré sur ce poste.');
        }
      }
      return;
    }
    if (action == 'edit') return _create(customer);
    if (action == 'sales') {
      final api = ref.read(salesApiProvider);
      await showHistory(
        context,
        title: 'Achats — ${customer.name}',
        empty: 'Ce client n’a encore rien acheté.',
        load: () async => [
          for (final s in (await api.sales(
            limit: 100,
            customerId: customer.id,
          )).data)
            (
              title: [
                s.invoiceNumber ?? s.number,
                if (s.status == 'ANNULEE') 'annulée',
              ].join(' · '),
              subtitle: [
                formatDateTime(s.soldAt),
                '${s.lines.length} article(s)',
                if (s.remainingAmount > 0)
                  'reste ${formatDA(s.remainingAmount)}',
              ].join(' · '),
              trailing: formatDA(s.totalTtc),
              at: s.soldAt,
            ),
        ],
      );
      return;
    }
    final actions = ref.read(salesActionsProvider);
    await showPaymentHistory(
      context,
      title: 'Règlements — ${customer.name}',
      load: () => actions.customerPayments(customer.id),
      onReverse: rights.canReversePayments
          ? (payment, reason) =>
                actions.reverseCustomerPayment(payment.id, reason)
          : null,
    );
  }

  /// Les chiffres de la liste affichée : combien, combien doivent, combien.
  Widget _customersSummary(AmpereColors colors, List<Customer> items) {
    final debtors = items.where((c) => c.balanceDue > 0).toList();
    final overdue = items.fold(0, (sum, c) => sum + c.overdueAmount);
    return SummaryStrip(
      items: [
        ('Clients', '${items.length}', colors.accentHi),
        ('Avec une dette', '${debtors.length}', colors.warn),
        (
          'Total dû',
          formatDA(debtors.fold(0, (sum, c) => sum + c.balanceDue)),
          colors.warn,
        ),
        if (overdue > 0) ('En retard', formatDA(overdue), colors.error),
      ],
    );
  }

  /// Fiche contact en carte : statut en couleur, crédit utilisé, gestes.
  Widget _customerCard(AmpereColors colors, Customer c) {
    final rights = widget.rights;
    final (status, tone) = c.overdueAmount > 0
        ? ('En retard ${formatDA(c.overdueAmount)}', colors.error)
        : c.balanceDue > 0
        ? ('Dette ${formatDA(c.balanceDue)}', colors.warn)
        : ('À jour', colors.ok);
    return ContactCard(
      name: c.name,
      phone: c.phone,
      tags: [if (c.isConfrere) 'Confrère'],
      status: status,
      tone: tone,
      gauge: c.creditLimit > 0 && !c.isConfrere
          ? (
              ratio: c.balanceDue / c.creditLimit,
              label:
                  'Crédit utilisé ${formatDA(c.balanceDue)} sur '
                  '${formatDA(c.creditLimit)}',
            )
          : null,
      actions: [
        if (rights.canSell)
          (LucideIcons.shoppingCart, 'Vendre', () => widget.onSell(c)),
        if (rights.canTakePayments && c.balanceDue > 0)
          (LucideIcons.banknote, 'Encaisser', () => _pay(c)),
        (LucideIcons.idCard, 'Fiche', () => _openCustomer(c)),
      ],
      onTap: () => _openCustomer(c),
    );
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
              if (widget.rights.canImportCustomers)
                ImportButton(
                  kind: ImportKind.customers,
                  onImported: () => ref.invalidate(customerSearchProvider),
                ),
              ExportButton(
                targets: [
                  ExportTarget(
                    'Clients',
                    ref.read(salesApiProvider).exportCustomers,
                  ),
                  ExportTarget(
                    'Dettes clients',
                    (format) => ref
                        .read(salesApiProvider)
                        .exportCustomers(format, debtOnly: true),
                  ),
                ],
              ),
              if (widget.rights.canWriteCustomers) ...[
                const SizedBox(width: 12),
                if (isDesktopWidth(MediaQuery.sizeOf(context).width))
                  FilledButton.icon(
                    onPressed: _create,
                    icon: const Icon(LucideIcons.plus, size: 17),
                    label: const Text('Nouveau client'),
                  )
                else
                  IconButton.filled(
                    tooltip: 'Nouveau client',
                    onPressed: _create,
                    icon: const Icon(LucideIcons.userPlus, size: 18),
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
                      _customersSummary(colors, items),
                      const SizedBox(height: 14),
                      ContactGrid(
                        children: [
                          for (final c in items) _customerCard(colors, c),
                        ],
                      ),
                    ],
                  ),
          ),
        ),
      ],
    );
  }
}

/// Geste du panier : contour et texte dans sa couleur (ambre remise, bleu
/// devis, rouge vider) — lisible d'un coup d'œil, jamais une icône seule.
class _CartAction extends StatelessWidget {
  const _CartAction({
    required this.icon,
    required this.label,
    required this.color,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
    style: OutlinedButton.styleFrom(
      minimumSize: const Size(0, 32),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      textStyle: AmpereType.bodyStrong,
    ),
    onPressed: onPressed,
    icon: Icon(icon, size: 14, color: onPressed == null ? null : color),
    label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
  );
}

/// Fait glisser et apparaître un élément à sa PREMIÈRE construction.
class _AppearIn extends StatelessWidget {
  const _AppearIn({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: 0, end: 1),
    duration: const Duration(milliseconds: 280),
    curve: Curves.easeOutCubic,
    builder: (context, t, child) => Opacity(
      opacity: t,
      child: Transform.translate(offset: Offset(24 * (1 - t), 0), child: child),
    ),
    child: child,
  );
}
