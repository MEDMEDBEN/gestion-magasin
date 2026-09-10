import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gestion_magasin/core/error/api_exception.dart';
import 'package:gestion_magasin/core/providers.dart';
import 'package:gestion_magasin/data/api/users_api.dart';
import 'package:gestion_magasin/data/models/user_models.dart';
import 'package:gestion_magasin/features/users/application/users_controller.dart';
import 'package:gestion_magasin/features/users/presentation/users_screen.dart';
import 'package:gestion_magasin/ui/theme/app_theme.dart';
import 'package:gestion_magasin/ui/widgets/screen_state.dart';

ManagedUser _user({
  String id = 'u1',
  String fullName = 'Amine Benali',
  String? email = 'amine@magasin.dz',
  bool isActive = true,
  bool mustChangePassword = false,
  List<String> roles = const ['VENDEUR'],
}) {
  return ManagedUser(
    id: id,
    email: email,
    phone: null,
    fullName: fullName,
    isActive: isActive,
    mustChangePassword: mustChangePassword,
    roles: roles,
    permissions: const ['sale.create'],
    lastLoginAt: null,
    createdAt: DateTime.utc(2026, 9, 1),
  );
}

/// Faux `UsersApi` : rend ce qu'on lui dicte, sans réseau.
class _FakeUsersApi implements UsersApi {
  _FakeUsersApi({this.users = const []});

  List<ManagedUser> users;
  ApiException? failure;

  @override
  Future<UserPage> list({int page = 1, int limit = 50, String? query}) async {
    if (failure != null) throw failure!;
    final filtered = query == null || query.isEmpty
        ? users
        : users
            .where(
              (u) => u.fullName.toLowerCase().contains(query.toLowerCase()),
            )
            .toList();
    return UserPage(
      data: filtered,
      meta: PageMeta(page: page, limit: limit, total: filtered.length),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('non utilisé par ce test');
}

Widget _wrap(_FakeUsersApi api, {String? initialSearch}) {
  return ProviderScope(
    overrides: [
      usersApiProvider.overrideWithValue(api),
      if (initialSearch != null)
        userSearchProvider.overrideWith(() => _SeededSearch(initialSearch)),
    ],
    child: MaterialApp(
      theme: AppTheme.mobile(dark: true),
      home: const UsersScreen(),
    ),
  );
}

class _SeededSearch extends UserSearchController {
  _SeededSearch(this.seed);
  final String seed;

  @override
  String build() => seed;
}

void main() {
  testWidgets('affiche la liste des comptes avec leur rôle', (tester) async {
    final api = _FakeUsersApi(
      users: [
        _user(),
        _user(id: 'u2', fullName: 'Karim Saidi', roles: const ['MAGASINIER']),
      ],
    );

    await tester.pumpWidget(_wrap(api));
    await tester.pumpAndSettle();

    expect(find.text('Amine Benali'), findsOneWidget);
    expect(find.text('Karim Saidi'), findsOneWidget);
    // Le rôle est traduit, pas affiché sous son code technique.
    expect(find.text('Vendeur / Caissier'), findsOneWidget);
    expect(find.text('Magasinier'), findsOneWidget);
  });

  testWidgets('signale un compte désactivé par un LIBELLÉ, pas une couleur', (
    tester,
  ) async {
    final api = _FakeUsersApi(users: [_user(isActive: false)]);

    await tester.pumpWidget(_wrap(api));
    await tester.pumpAndSettle();

    expect(find.text('Désactivé'), findsOneWidget);
  });

  testWidgets('signale un mot de passe temporaire', (tester) async {
    final api = _FakeUsersApi(users: [_user(mustChangePassword: true)]);

    await tester.pumpWidget(_wrap(api));
    await tester.pumpAndSettle();

    expect(find.text('Mot de passe temporaire'), findsOneWidget);
  });

  testWidgets('liste vide : propose de créer le premier compte', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(_FakeUsersApi()));
    await tester.pumpAndSettle();

    expect(find.text('Aucun utilisateur'), findsOneWidget);
    expect(
      find.widgetWithText(FilledButton, 'Nouvel utilisateur'),
      findsOneWidget,
    );
  });

  testWidgets('recherche sans résultat : reprend le terme cherché', (
    tester,
  ) async {
    final api = _FakeUsersApi(users: [_user()]);

    await tester.pumpWidget(_wrap(api, initialSearch: 'zzz'));
    await tester.pumpAndSettle();

    expect(find.text('Aucun résultat'), findsOneWidget);
    expect(find.textContaining('zzz'), findsOneWidget);
  });

  testWidgets('hors ligne : le dit, et propose de réessayer', (tester) async {
    final api = _FakeUsersApi()
      ..failure = const ApiException(
        statusCode: 0,
        message: 'Serveur injoignable',
      );

    await tester.pumpWidget(_wrap(api));
    await tester.pumpAndSettle();

    expect(find.text('Hors connexion'), findsOneWidget);
    expect(find.text('Réessayer'), findsOneWidget);
  });

  testWidgets('erreur serveur : état d’erreur, saisie garantie', (
    tester,
  ) async {
    final api = _FakeUsersApi()
      ..failure = const ApiException(
        statusCode: 500,
        message: 'Erreur interne du serveur',
      );

    await tester.pumpWidget(_wrap(api));
    await tester.pumpAndSettle();

    expect(find.byType(ScreenStateView), findsOneWidget);
    expect(find.text('Réessayer'), findsOneWidget);
  });

  testWidgets('affiche le total de comptes', (tester) async {
    final api = _FakeUsersApi(users: [_user(), _user(id: 'u2')]);

    await tester.pumpWidget(_wrap(api));
    await tester.pumpAndSettle();

    expect(find.text('2 comptes'), findsOneWidget);
  });
}
