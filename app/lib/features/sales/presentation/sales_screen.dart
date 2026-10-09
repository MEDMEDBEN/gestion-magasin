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
import '../../../ui/widgets/export_button.dart';
import '../../../ui/widgets/screen_state.dart';
import '../../auth/data/auth_models.dart';
import '../../catalog/application/catalog_controller.dart';
import '../../catalog/data/catalog_models.dart';
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
import 'confreres_section.dart';
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
    final margin = isDesktop
        ? AmpereGeometry.screenMarginDesktop
        : AmpereGeometry.screenMarginMobile;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(margin, 14, margin, 0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: _SectionTabs(
                    selected: _section,
                    onSelect: (section) => setState(() => _section = section),
                    items: [
                      (_Section.sale, LucideIcons.shoppingCart, 'Vente'),
                      // Miroir de `GET /sales` : ADMIN|VENDEUR + sale.create.
                      if (rights.canSell)
                        (_Section.history, LucideIcons.history, 'Historique'),
                      (_Section.customers, LucideIcons.users, 'Clients'),
                      if (rights.canSeeConfreres)
                        (
                          _Section.confreres,
                          LucideIcons.handshake,
                          'Confrères',
                        ),
                      if (rights.canSeeAllCash)
                        (
                          _Section.cashSessions,
                          LucideIcons.landmark,
                          'Caisses',
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // Miroir de `GET /sales/export` : ADMIN|VENDEUR + `sale.create`.
              // Le vendeur n'y trouve que SES ventes (le serveur filtre).
              if (rights.canSell)
                ExportButton(
                  targets: [
                    ExportTarget(
                      'Ventes (90 jours)',
                      ref.read(salesApiProvider).exportSales,
                    ),
                  ],
                ),
            ],
          ),
        ),
        Expanded(
          child: switch (_section) {
            _Section.sale => _SaleSection(margin: margin, rights: rights),
            _Section.history => SalesHistorySection(
              margin: margin,
              rights: rights,
            ),
            _Section.customers => _CustomersSection(
              margin: margin,
              rights: rights,
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

/// Onglets de l'écran Vente : des pastilles qui défilent (le téléphone n'a
/// pas la place de 5 segments), l'onglet choisi en dégradé d'accent.
class _SectionTabs extends StatelessWidget {
  const _SectionTabs({
    required this.items,
    required this.selected,
    required this.onSelect,
  });

  final List<(_Section, IconData, String)> items;
  final _Section selected;
  final ValueChanged<_Section> onSelect;

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: colors.surface2,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colors.lineSoft),
      ),
      // Téléphone : les pastilles passent à la ligne, toutes visibles.
      child: Wrap(
        runSpacing: 4,
        children: [
          for (final (section, icon, label) in items)
            _tab(colors, section, icon, label),
        ],
      ),
    );
  }

  Widget _tab(
    AmpereColors colors,
    _Section section,
    IconData icon,
    String label,
  ) {
    final on = section == selected;
    final ink = on ? colors.onAccent : colors.ink2;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => onSelect(section),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              gradient: on
                  ? LinearGradient(colors: [colors.accent, colors.accentHi])
                  : null,
              boxShadow: on
                  ? [
                      BoxShadow(
                        color: colors.accent.withValues(alpha: 0.35),
                        blurRadius: 12,
                        offset: const Offset(0, 3),
                      ),
                    ]
                  : null,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 16, color: ink),
                const SizedBox(width: 7),
                Text(label, style: AmpereType.bodyStrong.copyWith(color: ink)),
              ],
            ),
          ),
        ),
      ),
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

/// Carte « tiroir-caisse » : teinte d'état en dégradé, icône, titre, détail,
/// actions. Large : une ligne ; étroit, les actions passent dessous.
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
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: AmpereType.rowTitle.copyWith(color: colors.ink)),
        const SizedBox(height: 2),
        Text(subtitle, style: AmpereType.meta.copyWith(color: colors.ink2)),
      ],
    );
    final badge = Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Icon(icon, size: 20, color: tone),
    );
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: tone.withValues(alpha: 0.45)),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [tone.withValues(alpha: 0.16), tone.withValues(alpha: 0.03)],
        ),
      ),
      child: LayoutBuilder(
        builder: (context, box) => box.maxWidth >= 420
            ? Row(
                children: [
                  badge,
                  const SizedBox(width: 12),
                  Expanded(child: text),
                  trailing,
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      badge,
                      const SizedBox(width: 12),
                      Expanded(child: text),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Align(alignment: Alignment.centerRight, child: trailing),
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
  const _SaleSection({required this.margin, required this.rights});

  final double margin;
  final SalesRights rights;

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

  /// Ajout au ticket. Le message précédent (erreur d'encaissement…) part :
  /// en bas d'écran, il masquerait le bouton Encaisser.
  void _add(Product product) {
    ref.read(cartProvider.notifier).add(product);
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
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
          await _showTicket(sale, change: change);
        case Queued():
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
      if (mounted) _snack(context, error.userMessage);
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
    if (!widget.rights.canSell) {
      return const ScreenStateView(
        status: ScreenStatus.empty,
        title: 'Vente réservée aux vendeurs',
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
    if (_busy || estimate.blocked || cart.isEmpty || cart.quote != null) {
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
    return Padding(
      padding: EdgeInsets.fromLTRB(m, 14, m, m),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
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
                const SizedBox(height: 12),
                _CategoryChips(
                  products: products,
                  selected: _categoryId,
                  onSelect: (id) => setState(() => _categoryId = id),
                ),
                const SizedBox(height: 10),
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
          SizedBox(width: m),
          SizedBox(
            width: 420,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: AmpereColors.of(context).surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AmpereColors.of(context).line),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.all(16),
                      children: _ticketBody(),
                    ),
                  ),
                  _payPanel(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _narrowLayout(List<Product> products, Widget? catalogAlert) {
    final m = widget.margin;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: ListView(
            padding: EdgeInsets.fromLTRB(m, 14, m, 16),
            children: [
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
        const SizedBox(height: 12),
      ],
      Row(
        children: [
          Icon(LucideIcons.receipt, size: 18, color: colors.ink2),
          const SizedBox(width: 8),
          Text(
            'Ticket',
            style: AmpereType.sectionTitle.copyWith(color: colors.ink),
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
      _DashedLine(color: colors.line),
      const SizedBox(height: 10),
      _CustomerPicker(customer: cart.customer),
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
          _CartLineRow(
            line: line,
            missingPrice: estimate.missingPrices.contains(line.product),
            invalidDiscount: estimate.invalidDiscounts.contains(line.product),
            totalHt: estimate.lineTotalsHt[line.product.id],
            unitPriceHt: estimate.unitPricesHt[line.product.id],
            tariffPriceHt: estimate.tariffPricesHt[line.product.id],
            canDiscount: widget.rights.canDiscount,
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
    return Padding(
      padding: EdgeInsets.all(compact ? 12 : 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _TotalDisplay(
            total: estimate.totalTtc,
            articles: cart.lines.length,
            compact: compact,
          ),
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
          SizedBox(height: compact ? 8 : 12),
          if (noCash && cart.customer == null && cart.quote == null)
            // Une caisse ne vit qu'un jour : avant la première vente
            // espèces, on compte le tiroir (décision du 2026-10-08).
            _PayButton(
              icon: LucideIcons.lockOpen,
              label: 'Ouvrir la caisse pour encaisser',
              height: compact ? 52 : 60,
              tone: AmpereColors.of(context).warn,
              onPressed: widget.rights.canManageCash
                  ? () => _openCashFlow(context, ref)
                  : null,
            )
          else if (cart.quote case final quote?)
            // Un devis en cours de modification ne s'encaisse pas ici : il se
            // met à jour, puis suit son cycle (envoi, acceptation, conversion).
            _PayButton(
              icon: LucideIcons.fileText,
              label: 'Mettre à jour le devis ${quote.number}',
              height: compact ? 52 : 60,
              onPressed: blocked ? null : _updateQuote,
            )
          else
            _PayButton(
              icon: LucideIcons.banknote,
              label: 'Encaisser ${formatDA(estimate.totalTtc)}',
              shortcut: compact ? null : 'F9',
              height: compact ? 52 : 60,
              onPressed: blocked ? null : () => _checkout(estimate),
            ),
          if (!cart.isEmpty) ...[
            SizedBox(height: compact ? 6 : 8),
            Row(
              children: [
                if (cart.quote == null)
                  Expanded(
                    // Même panier, aucun encaissement, aucun mouvement de stock.
                    child: OutlinedButton.icon(
                      onPressed: blocked ? null : _makeQuote,
                      icon: const Icon(LucideIcons.fileText, size: 17),
                      label: const Text('Faire un devis'),
                    ),
                  ),
                if (cart.quote == null) const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busy
                        ? null
                        : () => ref.read(cartProvider.notifier).clear(),
                    icon: const Icon(LucideIcons.x, size: 17),
                    label: const Text('Vider le panier'),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// Pointillés d'un ticket de caisse.
class _DashedLine extends StatelessWidget {
  const _DashedLine({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) => Row(
      children: [
        for (var i = 0; i < box.maxWidth ~/ 9; i++)
          Container(
            width: 5,
            height: 1.5,
            margin: const EdgeInsets.only(right: 4),
            color: color,
          ),
      ],
    ),
  );
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
    final amount = Text(
      formatDA(total),
      style: AmpereType.numericHero.copyWith(
        fontSize: compact ? 30 : 42,
        color: colors.accentHi,
        shadows: [
          Shadow(color: colors.accent.withValues(alpha: 0.55), blurRadius: 14),
        ],
      ),
    );
    final screen = BoxDecoration(
      borderRadius: BorderRadius.circular(compact ? 12 : 16),
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [colors.bgAlt, colors.bg],
      ),
      border: Border.all(color: colors.accent.withValues(alpha: 0.5)),
      boxShadow: [
        BoxShadow(
          color: colors.accent.withValues(alpha: 0.16),
          blurRadius: 18,
          offset: const Offset(0, 4),
        ),
      ],
    );
    if (compact) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: screen,
        child: Row(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'TOTAL',
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
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
      decoration: screen,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                'TOTAL À PAYER',
                style: AmpereType.label.copyWith(
                  color: colors.ink3,
                  letterSpacing: 1.2,
                ),
              ),
              const Spacer(),
              Text(
                '$articles article(s)',
                style: AmpereType.meta.copyWith(color: colors.ink3),
              ),
            ],
          ),
          const SizedBox(height: 6),
          FittedBox(
            alignment: Alignment.centerRight,
            fit: BoxFit.scaleDown,
            child: amount,
          ),
          Text(
            'Estimation — le montant exact est calculé par le serveur.',
            textAlign: TextAlign.end,
            style: AmpereType.meta.copyWith(color: colors.ink3, fontSize: 11),
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
    final tone = this.tone ?? colors.ok;
    final enabled = onPressed != null;
    final radius = BorderRadius.circular(16);
    return SizedBox(
      height: height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          color: enabled ? null : colors.surface3,
          gradient: enabled
              ? LinearGradient(
                  // Vert → turquoise ; une autre teinte s'éclaircit seule.
                  colors: [
                    tone,
                    tone == colors.ok
                        ? Color.lerp(tone, colors.accent, 0.45)!
                        : Color.lerp(tone, colors.ink, 0.25)!,
                  ],
                )
              : null,
          boxShadow: enabled
              ? [
                  BoxShadow(
                    color: tone.withValues(alpha: 0.35),
                    blurRadius: 16,
                    offset: const Offset(0, 6),
                  ),
                ]
              : null,
        ),
        child: FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: Colors.transparent,
            disabledBackgroundColor: Colors.transparent,
            shadowColor: Colors.transparent,
            foregroundColor: colors.bg,
            disabledForegroundColor: colors.ink3,
            textStyle: AmpereType.sectionTitle,
            shape: RoundedRectangleBorder(borderRadius: radius),
          ),
          onPressed: onPressed,
          icon: Icon(icon, size: 22),
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
                    border: Border.all(color: colors.bg.withValues(alpha: 0.5)),
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
            spacing: 14,
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
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: tone,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      label,
                      style: AmpereType.meta.copyWith(color: colors.ink2),
                    ),
                  ],
                ),
            ],
          ),
          const SizedBox(height: 8),
        ],
        Expanded(
          child: GridView.builder(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 210,
              mainAxisExtent: 126,
              crossAxisSpacing: 10,
              mainAxisSpacing: 10,
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
        ? 'Rupture · ${product.sku}'
        : 'Stock ${formatQuantity(level)} ${product.unit.short} · ${product.sku}';
    return Material(
      color: picked ? colors.accentBg : colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: picked ? colors.accent : colors.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 28,
                height: 4,
                margin: const EdgeInsets.only(bottom: 7),
                decoration: BoxDecoration(
                  color: tone,
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        product.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: AmpereType.rowTitle.copyWith(color: colors.ink),
                      ),
                    ),
                    if (picked)
                      Container(
                        margin: const EdgeInsets.only(left: 6),
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
              ),
              Text(
                stockLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AmpereType.meta.copyWith(
                  color: level == null ? colors.ink3 : tone,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: price == null
                      ? colors.error.withValues(alpha: 0.14)
                      : colors.accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  price == null
                      ? 'Prix non fixé'
                      : '${formatDA(price!)} / ${product.unit.short}',
                  style: AmpereType.bodyStrong.copyWith(
                    color: price == null ? colors.error : colors.ink,
                    fontFeatures: AmpereType.tabular,
                  ),
                ),
              ),
            ],
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
    final value = await askAmount(
      context,
      title: 'Remise sur « ${line.product.name} »',
      label: 'Remise HT sur la ligne',
      confirm: 'Appliquer',
      initial: line.discountHt,
      help:
          'Ligne ${formatDA(gross)} HT · remise maximale '
          '${formatDA(maxDiscount)} (pas sous le coût)',
    );
    if (value == null || !context.mounted) return;
    // 0 retire la remise : toujours permis.
    if (value > maxDiscount) {
      _snack(
        context,
        'Remise trop forte : au plus ${formatDA(maxDiscount)} '
        '— la ligne ne descend pas sous le coût',
      );
      return;
    }
    ref.read(cartProvider.notifier).setDiscount(line.product.id, value);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = AmpereColors.of(context);
    final cart = ref.read(cartProvider.notifier);
    final compact = VisualDensity.compact;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.lineSoft)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  line.product.name,
                  style: AmpereType.rowTitle.copyWith(color: colors.ink),
                ),
              ),
              const SizedBox(width: 12),
              if (totalHt != null)
                Text(
                  formatDA(totalHt!),
                  style: AmpereType.bodyStrong.copyWith(
                    color: colors.ink,
                    fontFeatures: AmpereType.tabular,
                  ),
                ),
            ],
          ),
          Text(
            [
              line.product.sku,
              if (unitPriceHt != null)
                '${formatDA(unitPriceHt!)} / ${line.product.unit.short}',
              // Prix d'achat visible (2026-10-05) : savoir jusqu'où baisser.
              // Absent si inconnu ou non autorisé (serveur).
              if (line.product.lastPurchasePriceHt case final cost?)
                'achat ${formatDA(cost)}',
            ].join(' · '),
            style: AmpereType.meta.copyWith(color: colors.ink3),
          ),
          if (missingPrice)
            const AmpereBadge(label: 'Prix non fixé', tone: StatusTone.error)
          else if (unitPriceHt != tariffPriceHt)
            const AmpereBadge(label: 'Prix modifié', tone: StatusTone.warn),
          if (invalidDiscount)
            AmpereBadge(
              label:
                  'Remise ${formatDA(line.discountHt)} trop forte — à corriger',
              tone: StatusTone.error,
            )
          else if (line.discountHt > 0)
            Text(
              'Remise ${formatDA(line.discountHt)}',
              style: AmpereType.meta.copyWith(color: colors.warn),
            ),
          const SizedBox(height: 6),
          Row(
            children: [
              // Quantité : − 2 pce +, dans une pastille comme sur un terminal.
              DecoratedBox(
                decoration: BoxDecoration(
                  color: colors.surface2,
                  borderRadius: BorderRadius.circular(99),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      visualDensity: compact,
                      tooltip: 'Moins',
                      icon: const Icon(LucideIcons.minus, size: 16),
                      onPressed: () => cart.setQuantity(
                        line.product.id,
                        line.quantity - Quantity.one,
                      ),
                    ),
                    ConstrainedBox(
                      constraints: const BoxConstraints(minWidth: 56),
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
                      visualDensity: compact,
                      tooltip: 'Plus',
                      icon: const Icon(LucideIcons.plus, size: 16),
                      onPressed: () => cart.add(line.product),
                    ),
                  ],
                ),
              ),
              const Spacer(),
              IconButton(
                visualDensity: compact,
                tooltip: 'Modifier le prix',
                icon: const Icon(LucideIcons.pencil, size: 16),
                onPressed: () => _editPrice(context, ref),
              ),
              if (canDiscount && !missingPrice)
                IconButton(
                  visualDensity: compact,
                  tooltip: 'Remise',
                  icon: const Icon(LucideIcons.percent, size: 16),
                  onPressed: () => _editDiscount(context, ref),
                ),
              IconButton(
                visualDensity: compact,
                tooltip: 'Retirer',
                icon: Icon(LucideIcons.trash2, size: 16, color: colors.error),
                onPressed: () =>
                    cart.setQuantity(line.product.id, Quantity.zero),
              ),
            ],
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
            '${chosen.isConfrere ? 'confrère, sans plafond' : 'plafond ${formatDA(chosen.creditLimit)}'}',
        action: TextButton(
          onPressed: () => ref.read(cartProvider.notifier).setCustomer(null),
          child: const Text('Retirer'),
        ),
      );
    }
    final colors = AmpereColors.of(context);
    return Material(
      color: colors.surface2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: colors.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () async {
          final picked = await showDialog<Customer>(
            context: context,
            builder: (_) => const _CustomerSearchDialog(),
          );
          if (picked != null) {
            ref.read(cartProvider.notifier).setCustomer(picked);
          }
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Icon(LucideIcons.userPlus, size: 20, color: colors.accent),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Client (facultatif)',
                      style: AmpereType.rowTitle.copyWith(color: colors.ink),
                    ),
                    Text(
                      'Pour un crédit, une facture ou son tarif',
                      style: AmpereType.meta.copyWith(color: colors.ink3),
                    ),
                  ],
                ),
              ),
              Icon(LucideIcons.chevronRight, size: 18, color: colors.ink3),
            ],
          ),
        ),
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
                                  label: c.overdueAmount > 0
                                      ? 'En retard ${formatDA(c.overdueAmount)}'
                                      : c.balanceDue > 0
                                      ? 'Dette ${formatDA(c.balanceDue)}'
                                      : 'À jour',
                                  tone: c.overdueAmount > 0
                                      ? StatusTone.error
                                      : c.balanceDue > 0
                                      ? StatusTone.warn
                                      : StatusTone.ok,
                                ),
                              ],
                            ),
                            onTap: () => _openCustomer(c),
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
