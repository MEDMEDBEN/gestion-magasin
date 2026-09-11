import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../data/user_models.dart';
import '../data/users_api.dart';

/// Terme de recherche courant (barre de recherche de la liste).
class UserSearchController extends Notifier<String> {
  @override
  String build() => '';

  void set(String term) => state = term.trim();
  void clear() => state = '';
}

/// `autoDispose` : quitter l'écran (ou se déconnecter) libère la liste — sur un
/// poste partagé, les comptes chargés par l'admin ne restent pas en mémoire.
final userSearchProvider =
    NotifierProvider.autoDispose<UserSearchController, String>(
      UserSearchController.new,
    );

/// Liste chargée page après page.
@immutable
class UsersListState {
  const UsersListState({
    required this.items,
    required this.total,
    required this.page,
    this.isLoadingMore = false,
  });

  final List<ManagedUser> items;

  /// Total côté serveur — peut dépasser ce qui est chargé.
  final int total;
  final int page;
  final bool isLoadingMore;

  bool get hasMore => items.length < total;

  UsersListState copyWith({bool? isLoadingMore}) => UsersListState(
        items: items,
        total: total,
        page: page,
        isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      );
}

/// Liste paginée des comptes, filtrée par le terme courant.
class UsersController extends AsyncNotifier<UsersListState> {
  static const pageSize = 50;

  @override
  Future<UsersListState> build() {
    // Autre compte connecté → autre liste : rien de la session précédente.
    ref.watch(currentUserIdProvider);
    return _firstPage(ref.watch(userSearchProvider));
  }

  Future<UsersListState> _firstPage(String query) async {
    final page = await ref
        .read(usersApiProvider)
        .list(page: 1, limit: pageSize, query: query);
    return UsersListState(items: page.data, total: page.meta.total, page: 1);
  }

  /// Recharge la première page SANS repasser par le squelette : la liste reste
  /// affichée pendant l'appel (revue, suggestion 11).
  Future<void> refresh() async {
    state = await AsyncValue.guard(
      () => _firstPage(ref.read(userSearchProvider)),
    );
  }

  /// Charge la page suivante et l'ajoute à la liste. Au-delà de 50 comptes,
  /// rien ne doit rester invisible faute de pagination.
  Future<void> loadMore() async {
    final current = state.value;
    if (current == null || !current.hasMore || current.isLoadingMore) return;

    state = AsyncData(current.copyWith(isLoadingMore: true));
    try {
      final next = await ref.read(usersApiProvider).list(
            page: current.page + 1,
            limit: pageSize,
            query: ref.read(userSearchProvider),
          );
      state = AsyncData(
        UsersListState(
          items: [...current.items, ...next.data],
          total: next.meta.total,
          page: current.page + 1,
        ),
      );
    } catch (_) {
      state = AsyncData(current.copyWith(isLoadingMore: false));
      rethrow;
    }
  }

  /// Crée un compte, puis recharge la liste.
  /// Renvoie l'utilisateur créé pour que l'écran affiche une confirmation utile.
  Future<ManagedUser> create({
    String? email,
    String? phone,
    required String fullName,
    required String temporaryPassword,
    required List<String> roles,
    List<String> extraPermissions = const [],
  }) async {
    final created = await ref.read(usersApiProvider).create(
          email: email,
          phone: phone,
          fullName: fullName,
          temporaryPassword: temporaryPassword,
          roles: roles,
          extraPermissions: extraPermissions,
        );
    await refresh();
    return created;
  }

  /// N'envoie QUE les champs modifiés (voir `UserChanges`).
  Future<ManagedUser> updateUser(String id, UserChanges changes) async {
    final updated = await ref.read(usersApiProvider).update(id, changes);
    await refresh();
    return updated;
  }

  Future<void> setActive(String id, {required bool isActive}) async {
    await updateUser(id, UserChanges(isActive: isActive));
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
    AsyncNotifierProvider.autoDispose<UsersController, UsersListState>(
      UsersController.new,
    );

/// Rôles et permissions attribuables, lus sur le serveur (matrice validée).
final permissionCatalogProvider = FutureProvider.autoDispose<PermissionCatalog>(
  (ref) => ref.watch(usersApiProvider).permissionCatalog(),
);
