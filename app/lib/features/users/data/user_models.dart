import 'package:freezed_annotation/freezed_annotation.dart';

import '../../../data/models/page_meta.dart';

part 'user_models.freezed.dart';
part 'user_models.g.dart';

/// Miroir de `UserDto` (backend).
/// - `extraPermissions` : accordées À LA CARTE, en plus des rôles ;
/// - `permissions` : EFFECTIVES (rôles + à la carte), fusionnées par le serveur.
@freezed
abstract class ManagedUser with _$ManagedUser {
  const ManagedUser._();

  const factory ManagedUser({
    required String id,
    String? email,
    String? phone,
    required String fullName,
    required bool isActive,
    required bool mustChangePassword,
    required List<String> roles,
    @Default(<String>[]) List<String> extraPermissions,
    required List<String> permissions,
    DateTime? lastLoginAt,
    required DateTime createdAt,
  }) = _ManagedUser;

  factory ManagedUser.fromJson(Map<String, dynamic> json) =>
      _$ManagedUserFromJson(json);

  /// Identifiant de connexion affichable : email ou téléphone (spec §2bis).
  String get loginIdentifier => email ?? phone ?? '—';
}

/// Rôles FIGÉS du projet (`CLAUDE.md`) — le design system ne les modifie pas.
enum AppRole { admin, vendeur, magasinier }

extension AppRoleCode on AppRole {
  String get code => switch (this) {
        AppRole.admin => 'ADMIN',
        AppRole.vendeur => 'VENDEUR',
        AppRole.magasinier => 'MAGASINIER',
      };

  String get label => switch (this) {
        AppRole.admin => 'Administrateur',
        AppRole.vendeur => 'Vendeur / Caissier',
        AppRole.magasinier => 'Magasinier',
      };

  /// Ce que le rôle fait, en une ligne — évite à l'admin de deviner.
  String get description => switch (this) {
        AppRole.admin => 'Accès complet, validation et paramètres',
        AppRole.vendeur => 'Ventes, clients, caisse, demandes au dépôt',
        AppRole.magasinier => 'Stock dépôt, réceptions, transferts, inventaires',
      };

  static AppRole? fromCode(String code) => switch (code) {
        'ADMIN' => AppRole.admin,
        'VENDEUR' => AppRole.vendeur,
        'MAGASINIER' => AppRole.magasinier,
        _ => null,
      };
}

/// Libellé lisible d'une liste de codes de rôles.
String formatRoles(List<String> codes) => codes
    .map((c) => AppRoleCode.fromCode(c)?.label ?? c)
    .join(' · ');

@freezed
abstract class UserPage with _$UserPage {
  const factory UserPage({
    required List<ManagedUser> data,
    required PageMeta meta,
  }) = _UserPage;

  factory UserPage.fromJson(Map<String, dynamic> json) =>
      _$UserPageFromJson(json);
}

/// Miroir de `PermissionInfoDto`.
@freezed
abstract class PermissionInfo with _$PermissionInfo {
  const factory PermissionInfo({
    required String code,
    required String description,

    /// Réservée à l'ADMIN : jamais attribuable à la carte à un autre rôle.
    required bool adminOnly,
  }) = _PermissionInfo;

  factory PermissionInfo.fromJson(Map<String, dynamic> json) =>
      _$PermissionInfoFromJson(json);
}

/// Miroir de `RoleInfoDto`.
@freezed
abstract class RoleInfo with _$RoleInfo {
  const factory RoleInfo({
    required String code,
    required String name,
    required List<String> permissions,
  }) = _RoleInfo;

  factory RoleInfo.fromJson(Map<String, dynamic> json) =>
      _$RoleInfoFromJson(json);
}

/// Catalogue servi par `GET /users/permission-catalog` : l'app ne recopie PAS
/// la matrice de `docs/permissions.md`, elle la lit (source unique serveur).
@freezed
abstract class PermissionCatalog with _$PermissionCatalog {
  const PermissionCatalog._();

  const factory PermissionCatalog({
    required List<RoleInfo> roles,
    required List<PermissionInfo> permissions,
  }) = _PermissionCatalog;

  factory PermissionCatalog.fromJson(Map<String, dynamic> json) =>
      _$PermissionCatalogFromJson(json);

  /// Permissions déjà incluses par les rôles donnés.
  Set<String> includedBy(Iterable<String> roleCodes) => {
        for (final role in roles)
          if (roleCodes.contains(role.code)) ...role.permissions,
      };

  /// Permissions attribuables À LA CARTE à un compte portant ces rôles :
  /// ni déjà incluses par un rôle, ni réservées à l'ADMIN (règles fermes) si le
  /// compte n'est pas administrateur. Le serveur applique la même règle.
  List<PermissionInfo> grantableFor(Iterable<String> roleCodes) {
    final included = includedBy(roleCodes);
    final isAdmin = roleCodes.contains(AppRole.admin.code);
    return [
      for (final permission in permissions)
        if (!included.contains(permission.code) &&
            (isAdmin || !permission.adminOnly))
          permission,
    ];
  }
}

/// Modification partielle d'un compte : seuls les champs RENSEIGNÉS partent au
/// serveur. Ne jamais renvoyer un champ inchangé : sur un compte à rôles
/// cumulés, un formulaire qui renverrait « son » rôle principal effacerait les
/// autres sans que personne ne l'ait voulu (audit M10 / revue B2).
class UserChanges {
  const UserChanges({
    this.fullName,
    this.email,
    this.phone,
    this.isActive,
    this.roles,
    this.extraPermissions,
  });

  final String? fullName;
  final String? email;
  final String? phone;
  final bool? isActive;
  final List<String>? roles;
  final List<String>? extraPermissions;

  bool get isEmpty =>
      fullName == null &&
      email == null &&
      phone == null &&
      isActive == null &&
      roles == null &&
      extraPermissions == null;

  Map<String, dynamic> toJson() => {
        'fullName': ?fullName,
        'email': ?email,
        'phone': ?phone,
        'isActive': ?isActive,
        'roles': ?roles,
        'extraPermissions': ?extraPermissions,
      };
}
