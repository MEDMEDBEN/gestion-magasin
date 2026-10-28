import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gestion_magasin/core/providers.dart';
import 'package:gestion_magasin/data/local/app_database.dart';
import 'package:gestion_magasin/ui/theme/palettes.dart';
import 'package:gestion_magasin/ui/widgets/signal_background.dart';

/// Fond animé : allumé par défaut, éteignable, choix gardé PAR COMPTE.
void main() {
  test('éteint, le choix revient au compte qui se reconnecte', () async {
    final db = AppDatabase.forTesting();
    addTearDown(db.close);
    ProviderContainer open() => ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        currentUserIdProvider.overrideWith((ref) => 'u1'),
      ],
    );

    final first = open();
    first.listen(signalBackgroundProvider, (_, _) {});
    expect(first.read(signalBackgroundProvider), isTrue);
    await first.read(signalBackgroundProvider.notifier).toggle();
    expect(first.read(signalBackgroundProvider), isFalse);
    first.dispose();

    final again = open();
    addTearDown(again.dispose);
    again.listen(signalBackgroundProvider, (_, _) {});
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(again.read(signalBackgroundProvider), isFalse);
  });

  test('palette et style des LED gardés pour le compte', () async {
    final db = AppDatabase.forTesting();
    addTearDown(db.close);
    ProviderContainer open() => ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        currentUserIdProvider.overrideWith((ref) => 'u1'),
      ],
    );

    final first = open();
    first.listen(paletteProvider, (_, _) {});
    first.listen(ledStyleProvider, (_, _) {});
    expect(first.read(paletteProvider), isNull);
    await first.read(paletteProvider.notifier).set(AppPalette.synthwave);
    await first
        .read(ledStyleProvider.notifier)
        .set(colors: LedColors.ambre, ambiance: LedAmbiance.vive);
    first.dispose();

    final again = open();
    addTearDown(again.dispose);
    again.listen(paletteProvider, (_, _) {});
    again.listen(ledStyleProvider, (_, _) {});
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(again.read(paletteProvider), AppPalette.synthwave);
    expect(again.read(ledStyleProvider).colors, LedColors.ambre);
    expect(again.read(ledStyleProvider).ambiance, LedAmbiance.vive);
  });
}
