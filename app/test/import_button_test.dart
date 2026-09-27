import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gestion_magasin/core/error/api_exception.dart';
import 'package:gestion_magasin/core/file_import.dart';
import 'package:gestion_magasin/ui/theme/app_theme.dart';
import 'package:gestion_magasin/ui/widgets/import_button.dart';

import 'support/fakes.dart';

/// Import Excel/CSV : l'écran montre le verdict du serveur, n'importe qu'un
/// fichier sans erreur, et ne l'envoie qu'une fois vérifié à blanc.
class _FakeImportApi extends ImportApi {
  _FakeImportApi(this.check, {this.lostOnApply = false}) : super(Dio());

  final ImportReport check;

  /// La réponse de l'import appliqué se perd (réseau coupé, délai dépassé).
  final bool lostOnApply;
  final calls = <bool>[];

  @override
  Future<ImportReport> send(
    ImportKind kind,
    Uint8List bytes,
    String filename, {
    required bool dryRun,
  }) async {
    calls.add(dryRun);
    if (!dryRun && lostOnApply) {
      throw const ApiException(statusCode: 0, message: 'Serveur injoignable');
    }
    return dryRun
        ? check
        : ImportReport(
            dryRun: false,
            total: check.total,
            created: check.total,
            errors: const [],
          );
  }
}

Future<(_FakeImportApi, List<int>)> _pump(
  WidgetTester tester,
  ImportReport check, {
  int size = 3,
  bool lostOnApply = false,
}) async {
  useScreenSize(tester, const Size(900, 900));
  final api = _FakeImportApi(check, lostOnApply: lostOnApply);
  final refreshed = <int>[];
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        importApiProvider.overrideWithValue(api),
        pickImportFileProvider.overrideWithValue(
          () async => (bytes: Uint8List(size), name: 'clients.xlsx'),
        ),
      ],
      child: MaterialApp(
        theme: AppTheme.desktop(dark: true),
        home: Scaffold(
          body: Center(
            child: ImportButton(
              kind: ImportKind.customers,
              onImported: () => refreshed.add(1),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byTooltip('Importer'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Importer des clients…'));
  await tester.pumpAndSettle();
  return (api, refreshed);
}

void main() {
  testWidgets('erreurs : listées avec leur ligne, AUCUN import possible', (
    tester,
  ) async {
    final (api, refreshed) = await _pump(
      tester,
      const ImportReport(
        dryRun: true,
        total: 3,
        created: 0,
        errors: [
          ImportLineError(
            4,
            'Plafond de crédit : « dix » n’est pas un montant',
          ),
        ],
      ),
    );

    expect(
      find.text('3 ligne(s) lue(s) — 2 prête(s), 1 en erreur.'),
      findsOneWidget,
    );
    expect(
      find.text('Ligne 4 : Plafond de crédit : « dix » n’est pas un montant'),
      findsOneWidget,
    );
    expect(find.textContaining('Importer 2'), findsNothing);
    await tester.tap(find.text('Fermer'));
    await tester.pumpAndSettle();

    // Seule la vérification à blanc est partie.
    expect(api.calls, [true]);
    expect(refreshed, isEmpty);
  });

  testWidgets('fichier propre : vérifié à blanc, PUIS importé', (tester) async {
    final (api, refreshed) = await _pump(
      tester,
      const ImportReport(dryRun: true, total: 2, created: 0, errors: []),
    );

    await tester.tap(find.text('Importer 2 clients'));
    await tester.pumpAndSettle();

    expect(api.calls, [true, false]);
    expect(refreshed, [1]);
    expect(find.text('2 clients importé(s).'), findsOneWidget);
  });

  testWidgets('fichier de plus de 2 Mo : refusé sur le poste, rien d’envoyé', (
    tester,
  ) async {
    final (api, _) = await _pump(
      tester,
      const ImportReport(dryRun: true, total: 1, created: 0, errors: []),
      size: maxImportBytes + 1,
    );
    expect(api.calls, isEmpty);
    expect(find.textContaining('2 Mo au plus'), findsOneWidget);
  });

  testWidgets('colonnes non lues : montrées avant d’importer', (tester) async {
    await _pump(
      tester,
      const ImportReport(
        dryRun: true,
        total: 1,
        created: 0,
        errors: [],
        ignored: ['Prix TTC'],
      ),
    );
    expect(find.text('Colonnes non lues : Prix TTC.'), findsOneWidget);
  });

  /// L'import a peut-être abouti côté serveur : ne jamais dire « échec ».
  testWidgets('réponse perdue à l’import : « a peut-être abouti »', (
    tester,
  ) async {
    final (api, refreshed) = await _pump(
      tester,
      const ImportReport(dryRun: true, total: 2, created: 0, errors: []),
      lostOnApply: true,
    );
    await tester.tap(find.text('Importer 2 clients'));
    await tester.pumpAndSettle();
    expect(api.calls, [true, false]);
    expect(refreshed, isEmpty);
    expect(find.textContaining('a peut-être abouti'), findsOneWidget);
  });
}
