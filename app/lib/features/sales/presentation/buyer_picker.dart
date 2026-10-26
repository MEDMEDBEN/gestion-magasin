import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/error/api_exception.dart';
import '../../../core/money.dart';
import '../../../ui/theme/ampere_colors.dart';
import '../../../ui/theme/ampere_typography.dart';
import '../../../ui/widgets/contact_profile.dart';
import '../../../ui/widgets/screen_state.dart';
import '../application/sales_controller.dart';
import '../data/sales_api.dart';

/// Fournisseurs proposés comme acheteurs (en ligne).
final saleSuppliersProvider =
    FutureProvider.autoDispose<List<({String id, String name, String? phone})>>(
      (ref) => ref.watch(salesApiProvider).saleSuppliers(),
    );

/// Une ligne d'un choix : identifiant, nom, détail, badge éventuel.
typedef _Choice = ({
  String id,
  String name,
  String detail,
  String? badge,
  StatusTone tone,
});

/// Choix de l'acheteur (décision MEDMEDBEN du 2026-10-12) : vide par défaut,
/// obligatoire à CHAQUE vente. Passager directement ; Client, Confrère ou
/// Fournisseur ouvrent leur liste avec une recherche. Rend `true` si un
/// acheteur a été choisi.
Future<bool> chooseBuyer(
  BuildContext context,
  WidgetRef ref, {
  required bool withConfreres,
  required bool withSuppliers,
}) async {
  final kind = await showDialog<BuyerKind>(
    context: context,
    builder: (context) => _KindDialog(
      kinds: [
        BuyerKind.passager,
        BuyerKind.client,
        if (withConfreres) BuyerKind.confrere,
        if (withSuppliers) BuyerKind.fournisseur,
      ],
    ),
  );
  if (kind == null || !context.mounted) return false;
  final cart = ref.read(cartProvider.notifier);
  if (kind == BuyerKind.passager) {
    cart.setPassager();
    return true;
  }
  final api = ref.read(salesApiProvider);
  final picked = await showDialog<String>(
    context: context,
    builder: (_) => _ListDialog(kind: kind),
  );
  if (picked == null || !context.mounted) return false;
  try {
    final customerId = kind == BuyerKind.fournisseur
        ? await api.customerForSupplier(picked)
        : picked;
    cart.setCustomer(await api.customer(customerId), as: kind);
    return true;
  } on ApiException catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.userMessage)));
    }
    return false;
  }
}

class _KindDialog extends StatelessWidget {
  const _KindDialog({required this.kinds});

  final List<BuyerKind> kinds;

  static const _icons = {
    BuyerKind.passager: LucideIcons.user,
    BuyerKind.client: LucideIcons.users,
    BuyerKind.confrere: LucideIcons.handshake,
    BuyerKind.fournisseur: LucideIcons.truck,
  };

  static const _hints = {
    BuyerKind.passager: 'Sans fiche, payé comptant',
    BuyerKind.client: 'Crédit, facture, son tarif',
    BuyerKind.confrere: 'Dette sans plafond',
    BuyerKind.fournisseur: 'Comme un confrère',
  };

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    return AlertDialog(
      title: const Text('À qui vendez-vous ?'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final kind in kinds)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Material(
                  color: colors.surface2,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(color: colors.line),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: ListTile(
                    leading: Icon(_icons[kind], color: colors.accent),
                    title: Text(
                      kind.label,
                      style: AmpereType.bodyStrong.copyWith(color: colors.ink),
                    ),
                    subtitle: Text(_hints[kind]!),
                    trailing: Icon(
                      LucideIcons.chevronRight,
                      size: 18,
                      color: colors.ink3,
                    ),
                    onTap: () => Navigator.of(context).pop(kind),
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

/// Liste d'une catégorie d'acheteurs, avec recherche (nom ou téléphone).
class _ListDialog extends ConsumerStatefulWidget {
  const _ListDialog({required this.kind});

  final BuyerKind kind;

  @override
  ConsumerState<_ListDialog> createState() => _ListDialogState();
}

class _ListDialogState extends ConsumerState<_ListDialog> {
  String _query = '';

  AsyncValue<List<_Choice>> _choices() {
    switch (widget.kind) {
      case BuyerKind.client:
        return ref
            .watch(customerSearchProvider(_query))
            .whenData(
              (list) => [
                for (final c in list)
                  if (!c.isConfrere)
                    (
                      id: c.id,
                      name: c.name,
                      detail: c.phone ?? 'Sans téléphone',
                      badge: c.balanceDue > 0
                          ? 'Dette ${formatDA(c.balanceDue)}'
                          : null,
                      tone: c.overdueAmount > 0
                          ? StatusTone.error
                          : StatusTone.warn,
                    ),
              ],
            );
      case BuyerKind.confrere:
        return ref
            .watch(confreresProvider)
            .whenData(
              (list) => [
                for (final c in list)
                  (
                    id: c.id,
                    name: c.name,
                    detail: c.phone ?? 'Sans téléphone',
                    badge: c.net == 0
                        ? null
                        : c.net > 0
                        ? 'Il me doit ${formatDA(c.net)}'
                        : 'Je lui dois ${formatDA(-c.net)}',
                    tone: c.net > 0 ? StatusTone.ok : StatusTone.warn,
                  ),
              ],
            );
      case BuyerKind.fournisseur:
        return ref
            .watch(saleSuppliersProvider)
            .whenData(
              (list) => [
                for (final s in list)
                  (
                    id: s.id,
                    name: s.name,
                    detail: s.phone ?? 'Sans téléphone',
                    badge: null,
                    tone: StatusTone.neutral,
                  ),
              ],
            );
      case BuyerKind.passager:
        return const AsyncData([]);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    final term = _query.toLowerCase();
    final choices = _choices().whenData(
      (list) => widget.kind == BuyerKind.client || term.isEmpty
          ? list
          : [
              for (final c in list)
                if ('${c.name} ${c.detail}'.toLowerCase().contains(term)) c,
            ],
    );
    return AlertDialog(
      title: Text('Choisir un ${widget.kind.label.toLowerCase()}'),
      content: SizedBox(
        width: 460,
        height: 420,
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
              child: choices.when(
                loading: () => const AmpereSkeletonList(rows: 4),
                error: (error, _) => AmpereInlineAlert(
                  message: error is ApiException
                      ? error.userMessage
                      : 'Liste indisponible',
                ),
                data: (list) => list.isEmpty
                    ? Center(
                        child: Text(
                          'Aucun résultat',
                          style: AmpereType.body.copyWith(color: colors.ink3),
                        ),
                      )
                    : ListView(
                        children: [
                          for (final c in list)
                            ListTile(
                              leading: CircleAvatar(
                                backgroundColor: colors.accentBg,
                                child: Text(
                                  initialsOf(c.name),
                                  style: AmpereType.label.copyWith(
                                    color: colors.accentHi,
                                  ),
                                ),
                              ),
                              title: Text(c.name),
                              subtitle: Text(c.detail),
                              trailing: c.badge == null
                                  ? null
                                  : AmpereBadge(label: c.badge!, tone: c.tone),
                              onTap: () => Navigator.of(context).pop(c.id),
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

/// Bandeau « acheteur » du ticket : à choisir (obligatoire), ou celui choisi
/// avec « Changer ».
class BuyerBar extends ConsumerWidget {
  const BuyerBar({
    super.key,
    required this.withConfreres,
    required this.withSuppliers,
  });

  final bool withConfreres;
  final bool withSuppliers;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = AmpereColors.of(context);
    final cart = ref.watch(cartProvider);
    final buyer = cart.buyer;
    final customer = cart.customer;
    Future<void> choose() => chooseBuyer(
      context,
      ref,
      withConfreres: withConfreres,
      withSuppliers: withSuppliers,
    );
    final missing = buyer == null;
    final tone = missing ? colors.warn : colors.accent;
    final title = missing
        ? 'Choisir l’acheteur (obligatoire)'
        : customer == null
        ? buyer.label
        : '${buyer.label} · ${customer.name}';
    final detail = missing
        ? 'Passager, client, confrère ou fournisseur'
        : customer == null
        ? 'Vente comptant, sans fiche'
        : customer.isConfrere
        ? 'Dette ${formatDA(customer.balanceDue)} · sans plafond'
        : 'Dette ${formatDA(customer.balanceDue)} · plafond '
              '${formatDA(customer.creditLimit)}';
    // Sobre (maquette du 2026-10-26) : filet, l'icône porte l'état ; à
    // choisir, le filet est appuyé pour attirer l'œil sans colorer le fond.
    return Material(
      color: colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(
          color: missing ? tone : colors.line,
          width: missing ? 1.5 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: choose,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          child: Row(
            children: [
              Icon(
                missing ? LucideIcons.userRoundSearch : LucideIcons.userCheck,
                size: 15,
                color: tone,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AmpereType.bodyStrong.copyWith(color: colors.ink),
                    ),
                    Text(
                      detail,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AmpereType.meta.copyWith(color: colors.ink3),
                    ),
                  ],
                ),
              ),
              Text(
                missing ? 'Choisir' : 'Changer',
                style: AmpereType.bodyStrong.copyWith(color: colors.accent),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
