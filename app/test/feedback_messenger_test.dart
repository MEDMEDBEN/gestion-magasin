import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gestion_magasin/ui/theme/app_theme.dart';
import 'package:gestion_magasin/ui/widgets/feedback_messenger.dart';

/// Plus de barre qui monte du bas : un effet en haut, qui part seul.
void main() {
  Future<void> pump(WidgetTester tester, SnackBar snack) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.desktop(dark: false),
        builder: (context, child) => FeedbackMessenger(child: child!),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  ScaffoldMessenger.of(context).showSnackBar(snack),
              child: const Text('Agir'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Agir'));
    await tester.pump(const Duration(milliseconds: 600));
  }

  testWidgets('le message s’affiche en haut, puis disparaît seul', (
    tester,
  ) async {
    await pump(tester, const SnackBar(content: Text('Caisse ouverte.')));

    expect(find.text('Caisse ouverte.'), findsOneWidget);
    // Affiché en HAUT de l'écran, pas dans une barre du bas.
    expect(tester.getTopLeft(find.text('Caisse ouverte.')).dy, lessThan(200));

    await tester.pumpAndSettle();
    expect(find.text('Caisse ouverte.'), findsNothing);
  });

  testWidgets('le bouton utile d’une notification est gardé', (tester) async {
    var printed = false;
    await pump(
      tester,
      SnackBar(
        content: const Text('Retour enregistré'),
        action: SnackBarAction(
          label: 'Imprimer le bon',
          onPressed: () => printed = true,
        ),
      ),
    );

    await tester.tap(find.text('Imprimer le bon'));
    await tester.pumpAndSettle();
    expect(printed, isTrue);
    expect(find.text('Retour enregistré'), findsNothing);
  });

  // Capture (outil) : `--dart-define=CAPTURE_OUT=dossier`.
  const out = String.fromEnvironment('CAPTURE_OUT');
  for (final (name, message, dark) in [
    ('99a_notif_caisse', 'Caisse ouverte.', false),
    ('99b_notif_refus', 'Impression impossible sur ce poste.', true),
  ]) {
    testWidgets('capture $name', skip: out.isEmpty, (tester) async {
      tester.view.physicalSize = const Size(1000, 360);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            theme: AppTheme.desktop(dark: dark),
            builder: (context, child) => FeedbackMessenger(child: child!),
            home: Scaffold(
              body: Builder(
                builder: (context) => Center(
                  child: TextButton(
                    onPressed: () => ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(SnackBar(content: Text(message))),
                    child: const Text('Agir'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Agir'));
      // Première image : l'animation démarre ; puis on avance au milieu.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 900));
      await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        File('$out/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
      });
      await tester.pumpAndSettle();
    });
  }
}
