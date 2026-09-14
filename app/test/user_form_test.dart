import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gestion_magasin/core/providers.dart';
import 'package:gestion_magasin/features/users/data/user_models.dart';
import 'package:gestion_magasin/features/users/data/users_api.dart';
import 'package:gestion_magasin/features/users/presentation/user_form.dart';
import 'package:gestion_magasin/ui/theme/app_theme.dart';
import 'package:gestion_magasin/ui/widgets/screen_state.dart';

import 'support/fakes.dart';

/// Ouvre le formulaire depuis un bouton, comme le fait l'écran — le résultat
/// renvoyé par le formulaire est capturé dans [result].
class _Host extends StatelessWidget {
  const _Host({this.existing, this.onResult});

  final ManagedUser? existing;
  final void Function(ManagedUser?)? onResult;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: TextButton(
          onPressed: () async {
            // Hors de l'appel null-aware : `f?.call(await x)` n'évalue pas `x`
            // quand `f` est nul.
            final result = await openUserForm(
              context,
              existing: existing,
              currentUserId: 'me',
            );
            onResult?.call(result);
          },
          child: const Text('ouvrir'),
        ),
      ),
    );
  }
}

Future<FakeUsersApi> _open(
  WidgetTester tester, {
  ManagedUser? existing,
  Size size = const Size(420, 1400),
  void Function(ManagedUser?)? onResult,
}) async {
  useScreenSize(tester, size);
  final api = FakeUsersApi(users: [?existing]);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        usersApiProvider.overrideWithValue(api),
        currentUserIdProvider.overrideWithValue('me'),
      ],
      child: MaterialApp(
        theme: size.width >= 768 ? AppTheme.desktop(dark: true) : AppTheme.mobile(dark: true),
        home: _Host(existing: existing, onResult: onResult),
      ),
    ),
  );
  await tester.tap(find.text('ouvrir'));
  await tester.pumpAndSettle();
  return api;
}

Future<void> _save(WidgetTester tester, String label) async {
  final button = find.widgetWithText(FilledButton, label);
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('un compte à rôles CUMULÉS garde tous ses rôles, pré-cochés', (tester) async {
    await _open(
      tester,
      existing: managedUser(roles: const ['VENDEUR', 'MAGASINIER']),
    );

    expect(find.bySemanticsLabel(RegExp('Vendeur')), findsWidgets);
    final checked = tester
        .widgetList<Semantics>(find.byType(Semantics))
        .where((s) => s.properties.checked == true)
        .length;
    expect(checked, 2);
  });

  testWidgets('enregistrer SANS rien changer n’envoie rien au serveur', (tester) async {
    final api = await _open(
      tester,
      existing: managedUser(roles: const ['VENDEUR', 'MAGASINIER']),
    );

    await _save(tester, 'Enregistrer');

    expect(api.updates, isEmpty, reason: 'aucun changement de rôle fantôme');
  });

  testWidgets('changer le nom n’envoie QUE le nom — jamais les rôles', (tester) async {
    final api = await _open(
      tester,
      existing: managedUser(roles: const ['VENDEUR', 'MAGASINIER']),
    );

    await tester.enterText(find.byType(TextFormField).first, 'Amine B.');
    await _save(tester, 'Enregistrer');

    expect(api.updates.single.$2, {'fullName': 'Amine B.'});
  });

  testWidgets('un compte SANS rôle ne fait pas planter l’écran et exige un rôle', (tester) async {
    final api = await _open(tester, existing: managedUser(roles: const []));

    await _save(tester, 'Enregistrer');

    expect(find.text('Au moins un rôle est obligatoire'), findsOneWidget);
    expect(api.updates, isEmpty);
  });

  testWidgets('cumuler des fonctions = cocher plusieurs RÔLES ; aucune permission à la carte', (
    tester,
  ) async {
    final api = await _open(tester);

    // Décision 2026-09-13 : plus de section « Permissions supplémentaires ».
    expect(find.text('PERMISSIONS SUPPLÉMENTAIRES'), findsNothing);

    await tester.enterText(find.byType(TextFormField).at(0), 'Nadia Kaci');
    await tester.enterText(find.byType(TextFormField).at(1), 'nadia@magasin.dz');
    await tester.enterText(find.byType(TextFormField).at(3), 'MotDePasse1!');
    final magasinier = find.text('Magasinier');
    await tester.ensureVisible(magasinier);
    await tester.tap(magasinier);
    await _save(tester, 'Créer le compte');

    expect(api.creates.single.roles.toSet(), {'VENDEUR', 'MAGASINIER'});
  });

  testWidgets('SON propre compte : rôles verrouillés, expliqués, jamais envoyés', (tester) async {
    final api = await _open(
      tester,
      existing: managedUser(id: 'me', roles: const ['ADMIN']),
    );

    expect(find.textContaining('modifiés par un autre administrateur'), findsOneWidget);
    final magasinier = find.text('Magasinier');
    await tester.ensureVisible(magasinier);
    await tester.tap(magasinier);
    await tester.enterText(find.byType(TextFormField).first, 'Nouveau Nom');
    await _save(tester, 'Enregistrer');

    expect(api.updates.single.$2, {'fullName': 'Nouveau Nom'});
  });

  testWidgets('une erreur INATTENDUE libère le bouton et garde la saisie', (tester) async {
    final api = await _open(tester, existing: managedUser());
    api.updateFailure = StateError('panne imprévue');

    await tester.enterText(find.byType(TextFormField).first, 'Autre Nom');
    await _save(tester, 'Enregistrer');

    expect(find.text('Enregistrement impossible. Vos saisies sont conservées.'), findsOneWidget);
    final button = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Enregistrer'));
    expect(button.onPressed, isNotNull);
    expect(find.text('Autre Nom'), findsOneWidget);
  });

  testWidgets('le mot de passe temporaire n’est ni corrigé ni suggéré', (tester) async {
    await _open(tester);

    final field = tester.widget<TextField>(
      find.descendant(
        of: find.byType(TextFormField).at(3),
        matching: find.byType(TextField),
      ),
    );
    expect(field.autocorrect, isFalse);
    expect(field.enableSuggestions, isFalse);
  });

  testWidgets('desktop : panneau latéral de 440 px, pas de feuille basse', (tester) async {
    await _open(tester, size: const Size(1300, 900));

    expect(find.byType(BottomSheet), findsNothing);
    expect(tester.getSize(find.byType(UserForm)).width, 440);
  });

  testWidgets('mobile : plein écran, pas de feuille basse', (tester) async {
    await _open(tester, size: const Size(400, 800));

    expect(find.byType(BottomSheet), findsNothing);
    expect(tester.getSize(find.byType(UserForm)).width, 400);
    expect(find.byType(AmpereFieldLabel), findsWidgets);
  });
}
