import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/error/api_exception.dart';
import '../../../ui/theme/ampere_colors.dart';
import '../../../ui/widgets/fields_dialog.dart';
import '../../../ui/widgets/screen_state.dart';
import '../../auth/data/auth_models.dart';
import '../../catalog/application/catalog_controller.dart';
import '../data/settings_api.dart';

/// Droits de l'écran, MIROIRS des guards serveur.
class SettingsRights {
  SettingsRights(AuthUser user)
    : canManagePrices = user.hasRole('ADMIN') && user.can('price.manage'),
      canManageStore = user.hasRole('ADMIN') && user.can('settings.manage');

  /// `POST/PATCH /pricing/tiers` : ADMIN + price.manage.
  final bool canManagePrices;

  /// `GET/PATCH /settings/store` : ADMIN + settings.manage.
  final bool canManageStore;

  bool get any => canManagePrices || canManageStore;
}

const _storeLabels = {
  'name': 'Nom du magasin',
  'address': 'Adresse',
  'phone': 'Téléphone',
  'email': 'E-mail',
  'nif': 'NIF',
  'rc': 'Registre du commerce (RC)',
  'nis': 'NIS',
  'ai': 'Article d’imposition (AI)',
  'footer': 'Pied de page des bons et tickets (conditions, remerciement)',
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
        if (rights.canManageStore) const _PrintCard(),
        if (rights.canManagePrices) const _TiersCard(),
      ],
    );
  }
}

void _snack(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
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

// ── Impression ───────────────────────────────────────────────────────────────

const _ticketPapers = {
  'TICKET_80': 'Rouleau thermique 80 mm',
  'TICKET_58': 'Rouleau thermique 58 mm',
  'A5': 'Feuille A5 (bon de vente)',
  'A4': 'Feuille A4 (bon de vente)',
};

const _documentPapers = {'A4': 'Feuille A4', 'A5': 'Feuille A5'};

/// Formats d'impression, selon les imprimantes du magasin (décision MEDMEDBEN
/// du 2026-10-12) : ticket, documents (factures, devis, bons, bordereaux) et
/// taille de l'étiquette en rouleau.
class _PrintCard extends ConsumerStatefulWidget {
  const _PrintCard();

  @override
  ConsumerState<_PrintCard> createState() => _PrintCardState();
}

class _PrintCardState extends ConsumerState<_PrintCard> {
  final _width = TextEditingController();
  final _height = TextEditingController();
  StoreSettings? _loaded;
  String _ticket = 'TICKET_80';
  String _document = 'A4';
  bool _saving = false;

  @override
  void dispose() {
    _width.dispose();
    _height.dispose();
    super.dispose();
  }

  void _fill(StoreSettings store) {
    if (identical(store, _loaded)) return;
    _loaded = store;
    _ticket = store.ticketPaper;
    _document = store.documentPaper;
    _width.text = '${store.labelWidthMm}';
    _height.text = '${store.labelHeightMm}';
  }

  Future<void> _save() async {
    final width = int.tryParse(_width.text.trim());
    final height = int.tryParse(_height.text.trim());
    if (width == null || width < 20 || width > 150) {
      _snack(context, 'Largeur d’étiquette : de 20 à 150 mm.');
      return;
    }
    if (height == null || height < 15 || height > 150) {
      _snack(context, 'Hauteur d’étiquette : de 15 à 150 mm.');
      return;
    }
    setState(() => _saving = true);
    try {
      await ref.read(settingsApiProvider).saveStore({
        'ticketPaper': _ticket,
        'documentPaper': _document,
        'labelWidthMm': width,
        'labelHeightMm': height,
      });
      ref.invalidate(storeSettingsProvider);
      if (mounted) _snack(context, 'Formats d’impression enregistrés.');
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
      title: 'Impression',
      child: _asyncBody(store, () => ref.invalidate(storeSettingsProvider), (
        data,
      ) {
        _fill(data);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Choisissez les formats de VOS imprimantes : chaque ticket, bon '
              'et étiquette sortira à la bonne taille.',
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _ticket,
              decoration: const InputDecoration(labelText: 'Tickets de caisse'),
              items: [
                for (final e in _ticketPapers.entries)
                  DropdownMenuItem(value: e.key, child: Text(e.value)),
              ],
              onChanged: _saving
                  ? null
                  : (v) => setState(() => _ticket = v ?? _ticket),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _document,
              decoration: const InputDecoration(
                labelText: 'Factures, devis, bons et bordereaux',
              ),
              items: [
                for (final e in _documentPapers.entries)
                  DropdownMenuItem(value: e.key, child: Text(e.value)),
              ],
              onChanged: _saving
                  ? null
                  : (v) => setState(() => _document = v ?? _document),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _width,
                    enabled: !_saving,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Étiquette : largeur',
                      suffixText: 'mm',
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _height,
                    enabled: !_saving,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Étiquette : hauteur',
                      suffixText: 'mm',
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              'Taille de l’étiquette du rouleau (imprimante d’étiquettes). '
              'La planche A4 reste en 24 étiquettes 70 × 37 mm.',
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
          final values = await askFields(
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
                          final values = await askFields(
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
