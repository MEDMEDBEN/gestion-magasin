import 'package:freezed_annotation/freezed_annotation.dart';

part 'auth_models.freezed.dart';
part 'auth_models.g.dart';

/// Miroir de `AuthUserDto` (backend). Les permissions sont EFFECTIVES
/// (rôles + permissions accordées à la carte), déjà fusionnées par le serveur.
@freezed
abstract class AuthUser with _$AuthUser {
  const factory AuthUser({
    required String id,
    String? email,
    String? phone,
    required String fullName,
    required List<String> roles,
    required List<String> permissions,
    required bool mustChangePassword,
  }) = _AuthUser;

  factory AuthUser.fromJson(Map<String, dynamic> json) =>
      _$AuthUserFromJson(json);
}

/// L'UI masque ce que le serveur refuserait de toute façon — le backend
/// reste seul juge (CLAUDE.md règle 1). Les tests d'accès de l'UI sont le
/// MIROIR des guards serveur : rôle requis ET permission requise.
extension AuthUserAccess on AuthUser {
  bool hasRole(String role) => roles.contains(role);
  bool can(String permission) => permissions.contains(permission);
}

/// Miroir de `LoginResponseDto`.
@freezed
abstract class AuthSession with _$AuthSession {
  const AuthSession._();

  const factory AuthSession({
    required String accessToken,
    required String refreshToken,
    required int expiresIn,
    required AuthUser user,
  }) = _AuthSession;

  factory AuthSession.fromJson(Map<String, dynamic> json) =>
      _$AuthSessionFromJson(json);

  /// Masque les tokens : le `toString()` généré les imprimerait EN CLAIR.
  /// Une seule interpolation accidentelle (écran d'erreur Flutter, rapport de
  /// crash, log) suffirait à divulguer un refresh token valable 90 jours.
  @override
  String toString() => 'AuthSession(user: ${user.id}, expiresIn: $expiresIn)';
}
