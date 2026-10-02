import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gestion_magasin/core/providers.dart';
import 'package:gestion_magasin/data/local/app_database.dart';
import 'package:gestion_magasin/ui/desktop/desktop_shell.dart';

/// Compte connecté pilotable par le test.
class _TestUser extends Notifier<String?> {
  @override
  String? build() => null;
  void set(String? id) => state = id;
}

final _testUser = NotifierProvider<_TestUser, String?>(_TestUser.new);

/// Menu réduit / étendu : gardé PAR COMPTE sur le poste, comme le thème.
void main() {
  late AppDatabase db;
  late ProviderContainer container;

  setUp(() {
    db = AppDatabase.forTesting();
    container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        currentUserIdProvider.overrideWith((ref) => ref.watch(_testUser)),
      ],
    );
    container.listen(sidebarCollapsedProvider, (_, _) {});
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 20));

  test('sans choix : automatique (null)', () async {
    container.read(_testUser.notifier).set('compte-a');
    await settle();
    expect(container.read(sidebarCollapsedProvider), isNull);
  });

  test('le choix est retrouvé par son compte, pas par un autre', () async {
    container.read(_testUser.notifier).set('compte-a');
    await settle();
    await container
        .read(sidebarCollapsedProvider.notifier)
        .set(collapsed: true);

    container.read(_testUser.notifier).set('compte-b');
    await settle();
    expect(container.read(sidebarCollapsedProvider), isNull);

    container.read(_testUser.notifier).set('compte-a');
    await settle();
    expect(container.read(sidebarCollapsedProvider), isTrue);
  });

  test('un choix fait PENDANT la lecture n’est pas écrasé', () async {
    await container
        .read(localSettingsStoreProvider)
        .write('sidebar_collapsed.compte-a', 'true');

    container.read(_testUser.notifier).set('compte-a');
    container.read(sidebarCollapsedProvider); // lance la lecture…
    await container
        .read(sidebarCollapsedProvider.notifier)
        .set(collapsed: false); // …et on choisit
    await settle();

    expect(container.read(sidebarCollapsedProvider), isFalse);
  });
}
