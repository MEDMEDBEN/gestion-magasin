import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:gestion_magasin/core/error/api_exception.dart';
import 'package:gestion_magasin/data/local/token_store.dart';
import 'package:gestion_magasin/data/models/page_meta.dart';
import 'package:gestion_magasin/features/auth/data/auth_api.dart';
import 'package:gestion_magasin/features/auth/data/auth_models.dart';
import 'package:gestion_magasin/features/users/data/user_models.dart';
import 'package:gestion_magasin/features/users/data/users_api.dart';

/// Support de test partagé : faux clients d'API (aucun réseau), fabriques de
/// modèles, taille d'écran. Les faux enregistrent les appels pour que les
/// tests vérifient CE QUI PART au serveur, pas seulement ce qui s'affiche.

ManagedUser managedUser({
  String id = 'u1',
  String fullName = 'Amine Benali',
  String? email = 'amine@magasin.dz',
  String? phone,
  bool isActive = true,
  bool mustChangePassword = false,
  List<String> roles = const ['VENDEUR'],
  List<String> extraPermissions = const [],
  DateTime? lastLoginAt,
}) {
  return ManagedUser(
    id: id,
    email: email,
    phone: phone,
    fullName: fullName,
    isActive: isActive,
    mustChangePassword: mustChangePassword,
    roles: roles,
    extraPermissions: extraPermissions,
    permissions: const ['sale.create'],
    lastLoginAt: lastLoginAt,
    createdAt: DateTime.utc(2026, 9, 1),
  );
}

AuthUser authUser({
  String id = 'me',
  String fullName = 'Admin Principal',
  List<String> roles = const ['ADMIN'],
  List<String> permissions = const ['user.manage'],
}) {
  return AuthUser(
    id: id,
    email: 'admin@magasin.dz',
    fullName: fullName,
    roles: roles,
    permissions: permissions,
    mustChangePassword: false,
  );
}

/// Extrait de la matrice serveur, suffisant pour les écrans.
const testPermissionCatalog = PermissionCatalog(
  roles: [
    RoleInfo(
      code: 'ADMIN',
      name: 'Administrateur',
      permissions: [
        'product.read',
        'sale.create',
        'stock.loss',
        'supplier.read',
        'sale.discount',
        'user.manage',
      ],
    ),
    RoleInfo(
      code: 'VENDEUR',
      name: 'Vendeur / Caissier',
      permissions: ['product.read', 'sale.create'],
    ),
    RoleInfo(
      code: 'MAGASINIER',
      name: 'Magasinier',
      permissions: ['product.read', 'stock.loss', 'supplier.read'],
    ),
  ],
  permissions: [
    PermissionInfo(code: 'product.read', description: 'Consulter les produits', adminOnly: false),
    PermissionInfo(code: 'sale.create', description: 'Créer une vente', adminOnly: false),
    PermissionInfo(code: 'stock.loss', description: 'Déclarer une perte ou une casse', adminOnly: false),
    PermissionInfo(code: 'supplier.read', description: 'Consulter les fournisseurs', adminOnly: false),
    PermissionInfo(code: 'sale.discount', description: 'Appliquer une remise', adminOnly: true),
    PermissionInfo(code: 'user.manage', description: 'Gérer les utilisateurs', adminOnly: true),
  ],
);

class CreateCall {
  CreateCall(this.roles, this.extraPermissions, this.email, this.phone);
  final List<String> roles;
  final List<String> extraPermissions;
  final String? email;
  final String? phone;
}

/// Faux `UsersApi` : pagination réelle sur une liste en mémoire.
class FakeUsersApi implements UsersApi {
  FakeUsersApi({List<ManagedUser>? users}) : users = users ?? [];

  List<ManagedUser> users;
  ApiException? failure;
  Object? updateFailure;
  final List<(String, Map<String, dynamic>)> updates = [];
  final List<CreateCall> creates = [];
  final List<int> requestedPages = [];

  @override
  Future<UserPage> list({int page = 1, int limit = 50, String? query}) async {
    requestedPages.add(page);
    if (failure != null) throw failure!;
    final filtered = query == null || query.isEmpty
        ? users
        : users
            .where((u) => u.fullName.toLowerCase().contains(query.toLowerCase()))
            .toList();
    final start = (page - 1) * limit;
    final slice = filtered.skip(start).take(limit).toList();
    return UserPage(
      data: slice,
      meta: PageMeta(page: page, limit: limit, total: filtered.length),
    );
  }

  @override
  Future<PermissionCatalog> permissionCatalog() async => testPermissionCatalog;

  @override
  Future<ManagedUser> create({
    String? email,
    String? phone,
    required String fullName,
    required String temporaryPassword,
    required List<String> roles,
    List<String> extraPermissions = const [],
  }) async {
    creates.add(CreateCall(roles, extraPermissions, email, phone));
    final created = managedUser(
      id: 'new-${creates.length}',
      fullName: fullName,
      email: email,
      phone: phone,
      roles: roles,
      extraPermissions: extraPermissions,
      mustChangePassword: true,
    );
    users = [...users, created];
    return created;
  }

  @override
  Future<ManagedUser> update(String id, UserChanges changes) async {
    updates.add((id, changes.toJson()));
    if (updateFailure != null) throw updateFailure!;
    final current = users.firstWhere((u) => u.id == id);
    final updated = current.copyWith(
      fullName: changes.fullName ?? current.fullName,
      isActive: changes.isActive ?? current.isActive,
      roles: changes.roles ?? current.roles,
      extraPermissions: changes.extraPermissions ?? current.extraPermissions,
    );
    users = [for (final u in users) u.id == id ? updated : u];
    return updated;
  }

  @override
  Future<ManagedUser> resetPassword(String id, String temporaryPassword) async =>
      users.firstWhere((u) => u.id == id);

  @override
  Future<int> revokeSessions(String id) async => 2;
}

/// Faux `AuthApi` pilotable.
class FakeAuthApi implements AuthApi {
  ApiException? logoutFailure;
  ApiException? changePasswordFailure;
  final List<bool> logoutCalls = [];
  AuthUser user = authUser();

  /// Sessions que le serveur déclare fermées sur « tous appareils ».
  int allDevicesRevoked = 3;

  @override
  Future<int> logout({required String refreshToken, bool allDevices = false}) async {
    logoutCalls.add(allDevices);
    if (logoutFailure != null) throw logoutFailure!;
    return allDevices ? allDevicesRevoked : 1;
  }

  @override
  Future<AuthSession> changePassword({
    required String currentPassword,
    required String newPassword,
    String? deviceId,
  }) async {
    if (changePasswordFailure != null) throw changePasswordFailure!;
    return AuthSession(
      accessToken: 'access-2',
      refreshToken: 'refresh-2',
      expiresIn: 900,
      user: user,
    );
  }

  @override
  Future<AuthUser> me() async => user;

  @override
  Future<AuthSession> login({
    required String identifier,
    required String password,
    String? deviceId,
    String? deviceName,
  }) async =>
      AuthSession(accessToken: 'a', refreshToken: 'r', expiresIn: 900, user: user);
}

/// Stockage de tokens en mémoire (le plugin natif est absent en test).
class MemoryTokenStore extends TokenStore {
  MemoryTokenStore({this.access = 'access-1', this.refresh = 'refresh-1'});

  String? access;
  String? refresh;

  @override
  Future<String?> readAccessToken() async => access;

  @override
  Future<String?> readRefreshToken() async => refresh;

  @override
  Future<void> saveTokens({
    required String accessToken,
    required String refreshToken,
  }) async {
    access = accessToken;
    refresh = refreshToken;
  }

  @override
  Future<void> clear() async {
    access = null;
    refresh = null;
  }

  @override
  Future<String> deviceId(String Function() generate) async => 'appareil-test';
}

/// Fixe la taille logique de l'écran pour la durée du test.
void useScreenSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}
