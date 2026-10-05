import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gestion_magasin/features/catalog/data/catalog_models.dart';
import 'package:gestion_magasin/features/settings/data/settings_api.dart';
import 'package:gestion_magasin/features/settings/presentation/settings_screen.dart';
import 'package:gestion_magasin/ui/navigation.dart';
import 'package:gestion_magasin/ui/theme/app_theme.dart';

import 'support/fakes.dart';

/// Paramètres (P1 bis n°21h) : l'écran n'envoie que ce qui change, et ne
/// propose que les gestes que le serveur accepte.
class _FakeSettingsApi extends SettingsApi {
  _FakeSettingsApi() : super(Dio());

  final storeSaves = <Map<String, String?>>[];
  final tierSaves = <(String?, Map<String, Object?>)>[];

  @override
  Future<StoreSettings> store() async => const StoreSettings({
    'name': 'Magasin',
    'address': null,
    'phone': null,
    'nif': '000016001234567',
    'rc': null,
    'nis': null,
    'ai': null,
  });

  @override
  Future<StoreSettings> saveStore(Map<String, String?> changed) async {
    storeSaves.add(changed);
    return store();
  }

  @override
  Future<List<PriceTier>> tiers() async => const [
    PriceTier(id: 'd', code: 'DETAIL', name: 'Détail', isDefault: true),
    PriceTier(id: 'g', code: 'GROS', name: 'Gros', isDefault: false),
  ];

  @override
  Future<void> saveTier(String? id, Map<String, Object?> fields) async =>
      tierSaves.add((id, fields));
}

Future<_FakeSettingsApi> _pump(WidgetTester tester) async {
  useScreenSize(tester, const Size(900, 2000));
  final api = _FakeSettingsApi();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [settingsApiProvider.overrideWithValue(api)],
      child: MaterialApp(
        theme: AppTheme.desktop(dark: true),
        home: Scaffold(
          body: SettingsScreen(
            user: authUser(
              roles: const ['ADMIN'],
              permissions: const ['price.manage', 'settings.manage'],
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return api;
}

void main() {
  testWidgets('identité : seul le champ modifié part au serveur', (
    tester,
  ) async {
    final api = await _pump(tester);
    expect(find.text('000016001234567'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextField, 'Magasin'),
      'Électricité El Nour',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Enregistrer'));
    await tester.pumpAndSettle();
    expect(api.storeSaves, [
      {'name': 'Électricité El Nour'},
    ]);
  });

  testWidgets('tarifs : désigner le défaut ; le défaut ne se désactive pas', (
    tester,
  ) async {
    final api = await _pump(tester);
    // Menu du tarif par défaut : ni « par défaut », ni « Désactiver ».
    await tester.tap(find.byTooltip('Actions').first);
    await tester.pumpAndSettle();
    expect(find.text('Désactiver'), findsNothing);
    expect(find.text('Tarif par défaut'), findsNothing);
    await tester.tapAt(Offset.zero);
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Actions').at(1));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tarif par défaut'));
    await tester.pumpAndSettle();
    expect(api.tierSaves.single.$1, 'g');
    expect(api.tierSaves.single.$2, {'isDefault': true});
  });

  test('menu « Paramètres » : ADMIN avec le droit, jamais les autres', () {
    List<String> labels(List<String> roles, List<String> permissions) => [
      for (final d in destinationsFor(
        authUser(roles: roles, permissions: permissions),
      ))
        d.label,
    ];
    expect(
      labels(const ['ADMIN'], const ['settings.manage']),
      contains('Paramètres'),
    );
    expect(labels(const ['ADMIN'], const []), isNot(contains('Paramètres')));
    expect(
      labels(const ['VENDEUR'], const ['price.manage', 'settings.manage']),
      isNot(contains('Paramètres')),
    );
  });
}
