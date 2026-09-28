import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/error/api_exception.dart';
import '../../../ui/theme/ampere_colors.dart';
import '../../../ui/widgets/screen_state.dart';
import '../../auth/data/auth_models.dart';
import '../../catalog/application/catalog_controller.dart';
import '../data/settings_api.dart';

/// Droits de l'écran, MIROIRS des guards serveur.
class SettingsRights {
  SettingsRights(AuthUser user)
    : canManagePrices = user.hasRole('ADMIN') && user.can('price.manage'),
      canManageStore = user.hasRole('ADMIN') && user.can('settings.manage');

  /// `POST/PATCH /pricing/{tiers,tax-rates}` : ADMIN + price.manage.
  final bool canManagePrices;

  /// `GET/PATCH /settings/store` : ADMIN + settings.manage.
  final bool canManageStore;

  bool get any => canManagePrices || canManageStore;
}

const _storeLabels = {
  'name': 'Nom du magasin',
  'address': 'Adresse',
  'phone': 'Téléphone',
  'nif': 'NIF',
  'rc': 'Registre du commerce (RC)',
  'nis': 'NIS',
  'ai': 'Article d’imposition (AI)',
};

/// Paramètres (P1 bis n°21h) : identité imprimée sur les documents, tarifs,
/// taux de TVA. Tout est relu au serveur, qui décide.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({required this.user, super.key});

  final AuthUser user;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rights = SettingsRights(user);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (rights.canManageStore) const _StoreCard(),
        if (rights.canManagePrices) ...[
          const _TiersCard(),
          const _TaxRatesCard(),
        ],
      ],
    );
  }
}

void _snack(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

/// Petit formulaire en dialogue : `null` si annulé.
Future<Map<String, String>?> _askFields(
  BuildContext context, {
  required String title,
  required List<({String key, String label, String initial})> fields,
}) {
  final controllers = {
    for (final f in fields) f.key: TextEditingController(text: f.initial),
  };
  return showDialog<Map<String, String>>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final f in fields)
            TextField(
              controller: controllers[f.key],
              decoration: InputDecoration(labelText: f.label),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Annuler'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop({
            for (final e in controllers.entries) e.key: e.value.text.trim(),
          }),
          child: const Text('Enregistrer'),
        ),
      ],
    ),
  ).whenComplete(() {
    for (final c in controllers.values) {
      c.dispose();
    }
  });
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child, this.action});

  final String title;
  final Widget child;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(bottom: 16),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              ?action,
            ],
          ),
          const SizedBox(height: 8),
          child,
        ],
      ),
    ),
  );
}

Widget _asyncBody<T>(
  AsyncValue<T> value,
  VoidCallback retry,
  Widget Function(T data) data,
) => value.when(
  loading: () => const Padding(
    padding: EdgeInsets.all(16),
    child: Center(child: CircularProgressIndicator()),
  ),
  error: (error, _) => ScreenStateView(
    status: error is ApiException && error.isOffline
        ? ScreenStatus.offline
        : ScreenStatus.error,
    message: error is ApiException ? error.userMessage : '$error',
    onRetry: retry,
  ),
  data: data,
);

// ── Identité du magasin ─────────────────────────────────────────────────────

class _StoreCard extends ConsumerStatefulWidget {
  const _StoreCard();

  @override
  ConsumerState<_StoreCard> createState() => _StoreCardState();
}

class _StoreCardState extends ConsumerState<_StoreCard> {
  final _controllers = {
    for (final f in StoreSettings.fields) f: TextEditingController(),
  };
  StoreSettings? _loaded;
  bool _saving = false;

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _fill(StoreSettings store) {
    if (identical(store, _loaded)) return;
    _loaded = store;
    for (final f in StoreSettings.fields) {
      _controllers[f]!.text = store.values[f] ?? '';
    }
  }

  Future<void> _save() async {
    final loaded = _loaded;
    if (loaded == null) return;
    final changed = {
      for (final f in StoreSettings.fields)
        if (_controllers[f]!.text.trim() != (loaded.values[f] ?? ''))
          f: _controllers[f]!.text.trim(),
    };
    if (changed.isEmpty) return;
    setState(() => _saving = true);
    try {
      await ref.read(settingsApiProvider).saveStore(changed);
      ref.invalidate(storeSettingsProvider);
      if (mounted) _snack(context, 'Identité du magasin enregistrée.');
    } on ApiException catch (error) {
      if (mounted) _snack(context, error.userMessage);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = ref.watch(storeSettingsProvider);
    return _Section(
      title: 'Identité du magasin',
      child: _asyncBody(store, () => ref.invalidate(storeSettingsProvider), (
        data,
      ) {
        _fill(data);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Imprimée en tête des tickets, factures, devis et bons. NIF et '
              'RC sont obligatoires pour imprimer une facture. Un champ vidé '
              'reprend la valeur du serveur.',
            ),
            for (final f in StoreSettings.fields)
              TextField(
                controller: _controllers[f],
                enabled: !_saving,
                decoration: InputDecoration(labelText: _storeLabels[f]),
              ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: _saving ? null : _save,
                child: const Text('Enregistrer'),
              ),
            ),
          ],
        );
      }),
    );
  }
}

// ── Tarifs ───────────────────────────────────────────────────────────────────

class _TiersCard extends ConsumerWidget {
  const _TiersCard();

  Future<void> _run(
    BuildContext context,
    WidgetRef ref,
    Future<void> Function() action,
  ) async {
    try {
      await action();
      ref
        ..invalidate(settingsTiersProvider)
        ..invalidate(priceTiersProvider);
    } on ApiException catch (error) {
      if (context.mounted) _snack(context, error.userMessage);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.read(settingsApiProvider);
    final tiers = ref.watch(settingsTiersProvider);
    return _Section(
      title: 'Tarifs',
      action: TextButton.icon(
        icon: const Icon(Icons.add, size: 18),
        label: const Text('Nouveau tarif'),
        onPressed: () async {
          final values = await _askFields(
            context,
            title: 'Nouveau tarif',
            fields: const [
              (key: 'code', label: 'Code (ex. REVENDEUR)', initial: ''),
              (key: 'name', label: 'Nom', initial: ''),
            ],
          );
          if (values == null || !context.mounted) return;
          await _run(context, ref, () => api.saveTier(null, values));
        },
      ),
      child: _asyncBody(tiers, () => ref.invalidate(settingsTiersProvider), (
        items,
      ) {
        return Column(
          children: [
            for (final tier in items)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(tier.name),
                subtitle: Text(tier.code),
                trailing: Wrap(
                  spacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (tier.isDefault)
                      const AmpereBadge(
                        label: 'Par défaut',
                        tone: StatusTone.info,
                      ),
                    if (!tier.isActive)
                      const AmpereBadge(
                        label: 'Inactif',
                        tone: StatusTone.neutral,
                      ),
                    PopupMenuButton<String>(
                      tooltip: 'Actions',
                      onSelected: (choice) async {
                        if (choice == 'rename') {
                          final values = await _askFields(
                            context,
                            title: 'Renommer ${tier.code}',
                            fields: [
                              (key: 'name', label: 'Nom', initial: tier.name),
                            ],
                          );
                          if (values == null || !context.mounted) return;
                          await _run(
                            context,
                            ref,
                            () => api.saveTier(tier.id, values),
                          );
                        } else {
                          await _run(
                            context,
                            ref,
                            () => api.saveTier(tier.id, {
                              if (choice == 'default') 'isDefault': true,
                              if (choice == 'toggle')
                                'isActive': !tier.isActive,
                            }),
                          );
                        }
                      },
                      itemBuilder: (context) => [
                        const PopupMenuItem(
                          value: 'rename',
                          child: Text('Renommer'),
                        ),
                        if (!tier.isDefault && tier.isActive)
                          const PopupMenuItem(
                            value: 'default',
                            child: Text('Tarif par défaut'),
                          ),
                        if (!tier.isDefault)
                          PopupMenuItem(
                            value: 'toggle',
                            child: Text(
                              tier.isActive ? 'Désactiver' : 'Réactiver',
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
          ],
        );
      }),
    );
  }
}

// ── Taux de TVA ─────────────────────────────────────────────────────────────

class _TaxRatesCard extends ConsumerWidget {
  const _TaxRatesCard();

  Future<void> _run(
    BuildContext context,
    WidgetRef ref,
    Future<void> Function() action,
  ) async {
    try {
      await action();
      ref.invalidate(settingsTaxRatesProvider);
      // Les taux descendent par la synchro du catalogue (lecture hors ligne).
      await ref.read(catalogSyncProvider.notifier).refresh();
    } on ApiException catch (error) {
      if (context.mounted) _snack(context, error.userMessage);
    }
  }

  /// « 9,5 » → « 9.5 » : le serveur attend un pourcentage au point.
  static Map<String, String> _normalized(Map<String, String> values) => {
    ...values,
    if (values['rate'] != null) 'rate': values['rate']!.replaceAll(',', '.'),
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.read(settingsApiProvider);
    final rates = ref.watch(settingsTaxRatesProvider);
    return _Section(
      title: 'Taux de TVA',
      action: TextButton.icon(
        icon: const Icon(Icons.add, size: 18),
        label: const Text('Nouveau taux'),
        onPressed: () async {
          final values = await _askFields(
            context,
            title: 'Nouveau taux de TVA',
            fields: const [
              (key: 'code', label: 'Code (ex. TVA9)', initial: ''),
              (key: 'name', label: 'Nom (ex. TVA 9 %)', initial: ''),
              (key: 'rate', label: 'Taux en %', initial: ''),
            ],
          );
          if (values == null || !context.mounted) return;
          await _run(
            context,
            ref,
            () => api.saveTaxRate(null, _normalized(values)),
          );
        },
      ),
      child: _asyncBody(
        rates,
        () => ref.invalidate(settingsTaxRatesProvider),
        (items) => Column(
          children: [
            for (final rate in items)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(rate.name),
                subtitle: Text('${rate.code} · ${rate.rate} %'),
                trailing: Wrap(
                  spacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (rate.isDefault)
                      const AmpereBadge(
                        label: 'Par défaut',
                        tone: StatusTone.info,
                      ),
                    if (!rate.isActive)
                      const AmpereBadge(
                        label: 'Inactif',
                        tone: StatusTone.neutral,
                      ),
                    PopupMenuButton<String>(
                      tooltip: 'Actions',
                      onSelected: (choice) async {
                        if (choice == 'edit') {
                          final values = await _askFields(
                            context,
                            title: 'Modifier ${rate.code}',
                            fields: [
                              (key: 'name', label: 'Nom', initial: rate.name),
                              (
                                key: 'rate',
                                label: 'Taux en % (ventes futures)',
                                initial: rate.rate,
                              ),
                            ],
                          );
                          if (values == null || !context.mounted) return;
                          await _run(
                            context,
                            ref,
                            () => api.saveTaxRate(rate.id, _normalized(values)),
                          );
                        } else {
                          await _run(
                            context,
                            ref,
                            () => api.saveTaxRate(rate.id, {
                              if (choice == 'default') 'isDefault': true,
                              if (choice == 'toggle')
                                'isActive': !rate.isActive,
                            }),
                          );
                        }
                      },
                      itemBuilder: (context) => [
                        const PopupMenuItem(
                          value: 'edit',
                          child: Text('Modifier'),
                        ),
                        if (!rate.isDefault && rate.isActive)
                          const PopupMenuItem(
                            value: 'default',
                            child: Text('Taux par défaut'),
                          ),
                        if (!rate.isDefault)
                          PopupMenuItem(
                            value: 'toggle',
                            child: Text(
                              rate.isActive ? 'Désactiver' : 'Réactiver',
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
