import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../features/auth/data/auth_models.dart';
import '../features/auth/presentation/profile_screen.dart';
import '../features/catalog/presentation/catalog_screen.dart';
import '../features/users/presentation/users_screen.dart';
import 'widgets/screen_state.dart';

/// Une destination de navigation (entrée de sidebar desktop, onglet mobile).
class AppDestination {
  const AppDestination({
    required this.icon,
    required this.label,
    required this.builder,
  });

  final IconData icon;
  final String label;
  final Widget Function(BuildContext context, AuthUser user) builder;
}

/// Destinations proposées à un compte — SOURCE UNIQUE pour les deux coquilles.
///
/// Le menu est dérivé des droits (§6) : une entrée que le backend refuserait
/// n'est pas proposée. Chaque condition est le MIROIR du guard serveur de la
/// route correspondante (rôle requis ET permission requise) — l'UI masque, le
/// serveur reste seul juge (CLAUDE.md règle 1).
List<AppDestination> destinationsFor(AuthUser user) => [
  AppDestination(
    icon: LucideIcons.layoutGrid,
    label: 'Accueil',
    builder: (context, user) => ScreenStateView(
      status: ScreenStatus.empty,
      title: 'Bonjour ${user.fullName.split(' ').first}',
      message: 'Les modules arrivent avec les prochaines features P0.',
    ),
  ),
  // `/products`, `/categories`, `/locations` en lecture : 3 rôles + product.read.
  if (user.can('product.read'))
    AppDestination(
      icon: LucideIcons.package,
      label: 'Catalogue',
      builder: (context, user) => CatalogScreen(user: user),
    ),
  // `/users` : @Roles(ADMIN) + user.manage.
  if (user.hasRole('ADMIN') && user.can('user.manage'))
    AppDestination(
      icon: LucideIcons.shield,
      label: 'Utilisateurs',
      builder: (context, _) => const UsersScreen(),
    ),
  AppDestination(
    icon: LucideIcons.user,
    label: 'Mon profil',
    builder: (context, user) => ProfileScreen(user: user),
  ),
];
