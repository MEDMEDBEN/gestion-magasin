import 'package:freezed_annotation/freezed_annotation.dart';

part 'user_models.freezed.dart';
part 'user_models.g.dart';

/// Miroir de `UserDto` (backend). `permissions` est la liste EFFECTIVE
/// (rôles + permissions accordées à la carte), déjà fusionnée par le serveur.
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

/// `{ page, limit, total }` — enveloppe de liste imposée par CONVENTIONS.md.
@freezed
abstract class PageMeta with _$PageMeta {
  const factory PageMeta({
    required int page,
    required int limit,
    required int total,
  }) = _PageMeta;

  factory PageMeta.fromJson(Map<String, dynamic> json) =>
      _$PageMetaFromJson(json);
}
