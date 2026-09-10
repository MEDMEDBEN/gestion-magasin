import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../../../data/models/user_models.dart';

/// Terme de recherche courant (barre de recherche de la liste).
class UserSearchController extends Notifier<String> {
  @override
  String build() => '';

  void set(String term) => state = term.trim();
  void clear() => state = '';
}

final userSearchProvider =
    NotifierProvider<UserSearchController, String>(UserSearchController.new);

/// Liste paginée des utilisateurs, filtrée par le terme courant.
///
/// `AsyncNotifier` plutôt qu'un simple `FutureProvider` : après une création ou
/// une modification, le contrôleur doit pouvoir recharger sans que l'écran ait
/// à connaître le détail du rechargement.
class UsersController extends AsyncNotifier<UserPage> {
  @override
  Future<UserPage> build() {
    final query = ref.watch(userSearchProvider);
    return ref.read(usersApiProvider).list(query: query);
  }

  Future<void> refresh() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(
      () => ref.read(usersApiProvider).list(
            query: ref.read(userSearchProvider),
          ),
    );
  }

  /// Crée un compte, puis recharge la liste.
  /// Renvoie l'utilisateur créé pour que l'écran affiche une confirmation utile.
  Future<ManagedUser> create({
    String? email,
    String? phone,
    required String fullName,
    required String temporaryPassword,
    required List<String> roles,
  }) async {
    final created = await ref.read(usersApiProvider).create(
          email: email,
          phone: phone,
          fullName: fullName,
          temporaryPassword: temporaryPassword,
          roles: roles,
        );
    await refresh();
    return created;
  }

  Future<ManagedUser> updateUser(
    String id, {
    String? fullName,
    String? email,
    String? phone,
    bool? isActive,
    List<String>? roles,
  }) async {
    final updated = await ref.read(usersApiProvider).update(
          id,
          fullName: fullName,
          email: email,
          phone: phone,
          isActive: isActive,
          roles: roles,
        );
    await refresh();
    return updated;
  }

  Future<void> setActive(String id, {required bool isActive}) async {
    await updateUser(id, isActive: isActive);
  }

  Future<void> resetPassword(String id, String temporaryPassword) async {
    await ref.read(usersApiProvider).resetPassword(id, temporaryPassword);
    await refresh();
  }

  /// Ne recharge pas la liste : révoquer ne change aucune donnée affichée.
  Future<int> revokeSessions(String id) {
    return ref.read(usersApiProvider).revokeSessions(id);
  }
}

final usersControllerProvider =
    AsyncNotifierProvider<UsersController, UserPage>(UsersController.new);
