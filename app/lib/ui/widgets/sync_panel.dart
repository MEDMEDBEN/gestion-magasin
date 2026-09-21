import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/dates.dart';
import '../../core/providers.dart';
import '../../data/local/app_database.dart';
import '../../data/sync/sync_coordinator.dart';
import '../theme/ampere_colors.dart';
import '../theme/ampere_typography.dart';
import 'ampere_controls.dart';

/// Libellés des opérations synchronisables (enum `OperationType` du serveur).
const _operationLabels = <String, String>{
  'SALE': 'Vente',
  'RECEPTION': 'Réception',
  'TRANSFER': 'Transfert',
  'INVENTORY': 'Inventaire',
  'PURCHASE_ORDER': 'Commande fournisseur',
  'QUOTE': 'Devis',
  'CUSTOMER_PAYMENT': 'Règlement client',
  'SUPPLIER_PAYMENT': 'Paiement fournisseur',
  'CASH_SESSION': 'Caisse',
  'PRODUCT': 'Produit',
  'MANUAL': 'Opération',
};

/// Ouvre le panneau de synchronisation depuis l'indicateur de l'en-tête.
Future<void> showSyncPanel(BuildContext context) => showDialog<void>(
  context: context,
  barrierColor: AmpereColors.of(context).scrim,
  builder: (_) => const Dialog(child: SyncPanel()),
);

/// Ce qui attend, ce qui a été REFUSÉ et pourquoi (docs/context.md §6).
///
/// Un rejet n'est jamais effacé tout seul : l'utilisateur doit l'avoir LU. Il
/// « abandonne » la mutation (elle n'a rien changé côté serveur) puis refait
/// l'opération corrigée — une NOUVELLE mutation, jamais la même clé.
class SyncPanel extends ConsumerStatefulWidget {
  const SyncPanel({super.key});

  @override
  ConsumerState<SyncPanel> createState() => _SyncPanelState();
}

class _SyncPanelState extends ConsumerState<SyncPanel> {
  bool _syncing = false;

  Future<void> _syncNow() async {
    setState(() => _syncing = true);
    await ref.read(syncCoordinatorProvider.notifier).kick();
    if (mounted) setState(() => _syncing = false);
  }

  Future<void> _discard(PendingMutation mutation) async {
    final label = _operationLabels[mutation.operationType] ?? 'Opération';
    final confirmed = await showAmpereConfirmDialog(
      context,
      title: 'Abandonner cette opération ?',
      body:
          '« $label » a été refusée par le serveur : elle n’a rien modifié. '
          'L’abandonner la retire de cet appareil ; refaites-la si besoin.',
      confirmLabel: 'Abandonner',
    );
    final userId = ref.read(currentUserIdProvider);
    if (!confirmed || userId == null) return;
    await ref
        .read(mutationQueueProvider)
        .discard(mutation.clientMutationId, authorUserId: userId);
  }

  @override
  Widget build(BuildContext context) {
    final colors = AmpereColors.of(context);
    final pending = ref.watch(pendingMutationsCountProvider).value ?? 0;
    final rejected = ref.watch(rejectedMutationsProvider).value ?? const [];
    final reachable = ref.watch(serverReachableProvider);
    final failure = ref.watch(syncCoordinatorProvider)?.failure;

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560, maxHeight: 640),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Synchronisation',
              style: AmpereType.h4.copyWith(color: colors.ink),
            ),
            const SizedBox(height: 8),
            Text(
              pending == 0
                  ? 'Aucune opération en attente.'
                  : '$pending opération${pending > 1 ? 's' : ''} en attente '
                        '— pas encore confirmée${pending > 1 ? 's' : ''} '
                        'par le serveur.',
              style: AmpereType.body.copyWith(color: colors.ink),
            ),
            if (!reachable || failure != null) ...[
              const SizedBox(height: 4),
              Text(
                failure ?? 'Pas de connexion au serveur',
                style: AmpereType.meta.copyWith(color: colors.ink2),
              ),
            ],
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                onPressed: _syncing ? null : _syncNow,
                icon: const Icon(LucideIcons.refreshCw, size: 16),
                label: Text(
                  _syncing ? 'Synchronisation…' : 'Synchroniser maintenant',
                ),
              ),
            ),
            if (rejected.isNotEmpty) ...[
              const SizedBox(height: 20),
              Text(
                'Refusées par le serveur',
                style: AmpereType.h4.copyWith(color: colors.ink),
              ),
              const SizedBox(height: 8),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: rejected.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final m = rejected[i];
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        '${_operationLabels[m.operationType] ?? m.operationType}'
                        ' · ${formatDateTime(m.deviceTimestamp)}',
                      ),
                      subtitle: Text(
                        m.rejectionReason ??
                            m.rejectionCode ??
                            'Motif non précisé',
                      ),
                      trailing: TextButton(
                        onPressed: () => _discard(m),
                        child: const Text('Abandonner'),
                      ),
                    );
                  },
                ),
              ),
            ],
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Fermer'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
