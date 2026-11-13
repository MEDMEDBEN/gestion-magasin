import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gestion_magasin/ui/keyboard/keyboard.dart';
import 'package:gestion_magasin/ui/theme/app_theme.dart';
import 'package:gestion_magasin/ui/widgets/ampere_controls.dart';
import 'package:gestion_magasin/ui/widgets/form_panel.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

// Convention clavier unique (demande MEDMEDBEN du 2026-11-13).
Widget _app(Widget home) => MaterialApp(
  theme: AppTheme.desktop(dark: false),
  builder: (context, child) => KeyboardRoot(child: child!),
  home: home,
);

Future<void> _press(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  bool ctrl = false,
}) async {
  if (ctrl) await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(key);
  if (ctrl) await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('fenêtre : Entrée = bouton principal, Échap = annuler', (
    tester,
  ) async {
    bool? result;
    await tester.pumpWidget(
      _app(
        Builder(
          builder: (context) => TextButton(
            onPressed: () async => result = await showAmpereConfirmDialog(
              context,
              title: 'Supprimer ?',
              body: 'Irréversible.',
              confirmLabel: 'Supprimer',
            ),
            child: const Text('ouvrir'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('ouvrir'));
    await tester.pumpAndSettle();
    await _press(tester, LogicalKeyboardKey.enter);
    expect(result, isTrue);

    await tester.tap(find.text('ouvrir'));
    await tester.pumpAndSettle();
    await _press(tester, LogicalKeyboardKey.escape);
    expect(result, isFalse);
    expect(find.text('Supprimer ?'), findsNothing);
  });

  testWidgets('fenêtre sans bouton principal : Entrée n’annule PAS', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('Choisir'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Annuler'),
                  ),
                ],
              ),
            ),
            child: const Text('ouvrir'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('ouvrir'));
    await tester.pumpAndSettle();
    await _press(tester, LogicalKeyboardKey.enter);
    expect(find.text('Choisir'), findsOneWidget);
  });

  testWidgets('panneau : Entrée = champ suivant, Ctrl+S = enregistrer', (
    tester,
  ) async {
    var saved = 0;
    final first = FocusNode();
    final second = FocusNode();
    await tester.pumpWidget(
      _app(
        Scaffold(
          body: FormPanelFrame(
            formKey: GlobalKey<FormState>(),
            title: 'Client',
            onSubmit: () => saved++,
            children: [
              TextFormField(focusNode: first, autofocus: true),
              TextFormField(focusNode: second),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(first.hasFocus, isTrue);
    await _press(tester, LogicalKeyboardKey.enter);
    expect(second.hasFocus, isTrue);
    expect(saved, 0);
    await _press(tester, LogicalKeyboardKey.keyS, ctrl: true);
    expect(saved, 1);
    await _press(tester, LogicalKeyboardKey.enter, ctrl: true);
    expect(saved, 2);
  });

  testWidgets('page : Ctrl+F va à la recherche, Ctrl+N et Inser = Nouveau', (
    tester,
  ) async {
    var created = 0;
    final search = FocusNode();
    await tester.pumpWidget(
      _app(
        Scaffold(
          body: Column(
            children: [
              TextField(
                focusNode: search,
                decoration: const InputDecoration(
                  prefixIcon: Icon(LucideIcons.search),
                ),
              ),
              FilledButton(
                onPressed: () => created++,
                child: const Text('Nouveau produit'),
              ),
            ],
          ),
        ),
      ),
    );
    await _press(tester, LogicalKeyboardKey.keyF, ctrl: true);
    expect(search.hasFocus, isTrue);
    await _press(tester, LogicalKeyboardKey.keyN, ctrl: true);
    await _press(tester, LogicalKeyboardKey.insert);
    expect(created, 2);
  });

  testWidgets('F1 : la liste des raccourcis', (tester) async {
    await tester.pumpWidget(_app(const Scaffold(body: Text('page'))));
    await _press(tester, LogicalKeyboardKey.f1);
    expect(find.text('Raccourcis clavier'), findsOneWidget);
    expect(find.text('Aide : ces raccourcis'), findsOneWidget);
    await _press(tester, LogicalKeyboardKey.enter);
    expect(find.text('Raccourcis clavier'), findsNothing);
  });
}
