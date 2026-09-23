import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../features/audit/presentation/audit_screen.dart';
import '../features/auth/data/auth_models.dart';
import '../features/auth/presentation/profile_screen.dart';
import '../features/catalog/presentation/catalog_screen.dart';
import '../features/home/presentation/home_screen.dart';
import '../features/inventory/presentation/inventory_screen.dart';
import '../features/planning/presentation/planning_screen.dart';
import '../features/purchases/presentation/purchases_screen.dart';
import '../features/sales/presentation/sales_screen.dart';
import '../features/scan/presentation/scan_screen.dart';
import '../features/stock/presentation/stock_screen.dart';
import '../features/suppliers/presentation/suppliers_screen.dart';
import '../features/transfers/presentation/transfers_screen.dart';
import '../features/users/presentation/users_screen.dart';

/// Une destination de navigation (entrée de sidebar desktop, onglet mobile).
class AppDestination {
  const AppDestination({
    required this.icon,
    required this.label,
    required this.builder,
    this.mobileOnly = false,
  });

  final IconData icon;
  final String label;
  final Widget Function(BuildContext context, AuthUser user) builder;

  /// Réservée au mobile (ex. le scanner : il lui faut une caméra ; au poste,
  /// la douchette fait le travail dans l'écran Vente).
  final bool mobileOnly;
}

/// Destination demandée par un ÉCRAN (les raccourcis de l'accueil, spec §21).
///
/// Chaque coquille garde son propre onglet courant ; ce libellé est le seul
/// canal pour lui demander d'en changer. Il est remis à `null` dès qu'il est
/// suivi, sinon la coquille reviendrait sur cet onglet à chaque reconstruction.
class RequestedDestination extends Notifier<String?> {
  @override
  String? build() => null;

  void ask(String label) => state = label;

  void taken() => state = null;
}

final requestedDestinationProvider =
    NotifierProvider<RequestedDestination, String?>(RequestedDestination.new);

/// Demande à la coquille d'ouvrir la destination `label` (celui du menu).
void goToDestination(WidgetRef ref, String label) =>
    ref.read(requestedDestinationProvider.notifier).ask(label);

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
    builder: (context, user) => HomeScreen(user: user),
  ),
  // `/sales` : ADMIN|VENDEUR + sale.create.
  if ((user.hasRole('ADMIN') || user.hasRole('VENDEUR')) &&
      user.can('sale.create'))
    AppDestination(
      icon: LucideIcons.shoppingCart,
      label: 'Vente',
      builder: (context, user) => SalesScreen(user: user),
    ),
  // `/products`, `/categories`, `/locations` en lecture : 3 rôles + product.read.
  if (user.can('product.read'))
    AppDestination(
      icon: LucideIcons.package,
      label: 'Catalogue',
      builder: (context, user) => CatalogScreen(user: user),
    ),
  // `/stock` : 3 rôles + stock.read.store.
  if (user.can('stock.read.store'))
    AppDestination(
      icon: LucideIcons.warehouse,
      label: 'Stock',
      builder: (context, user) => StockScreen(user: user),
    ),
  // Scanner (spec §27) : les 3 rôles qui lisent le catalogue, MOBILE seulement
  // (il lui faut une caméra ; au poste, la douchette agit dans Vente). Placé
  // après les écrans du quotidien : il tombe donc dans « Plus » (AMPÈRE §7),
  // soit deux tapes — l'accueil en donne un raccourci direct (P1 n°15).
  if (user.can('product.read'))
    AppDestination(
      icon: LucideIcons.scanBarcode,
      label: 'Scanner',
      mobileOnly: true,
      builder: (context, user) => ScanScreen(user: user),
    ),
  // `/planning-tasks` : 3 rôles + planning.task.read ; chacun n'y voit que
  // SES tâches (le serveur cloisonne), l'admin voit tout et planifie.
  if (user.can('planning.task.read'))
    AppDestination(
      icon: LucideIcons.calendarCheck,
      label: 'Tâches',
      builder: (context, user) => PlanningScreen(user: user),
    ),
  // `/transfers` : les 3 rôles lisent la liste (guard de rôle seul) ; l'entrée
  // n'est proposée qu'à qui tient un bout du flux (demander, préparer, recevoir).
  if (user.can('transfer.request') ||
      user.can('transfer.prepare') ||
      user.can('transfer.receive'))
    AppDestination(
      icon: LucideIcons.arrowLeftRight,
      label: 'Transferts',
      builder: (context, user) => TransfersScreen(user: user),
    ),
  // `/purchase-orders` : ADMIN|MAGASINIER + purchase.create.
  if ((user.hasRole('ADMIN') || user.hasRole('MAGASINIER')) &&
      user.can('purchase.create'))
    AppDestination(
      icon: LucideIcons.clipboardList,
      label: 'Achats',
      builder: (context, user) => PurchasesScreen(user: user),
    ),
  // `/inventories` : ADMIN|MAGASINIER + inventory.create (la VALIDATION des
  // ajustements reste l'admin seul, vérifiée par le serveur).
  if ((user.hasRole('ADMIN') || user.hasRole('MAGASINIER')) &&
      user.can('inventory.create'))
    AppDestination(
      icon: LucideIcons.clipboardCheck,
      label: 'Inventaire',
      builder: (context, user) => InventoryScreen(user: user),
    ),
  // `/suppliers` : ADMIN|MAGASINIER + supplier.read (fermé au vendeur).
  if ((user.hasRole('ADMIN') || user.hasRole('MAGASINIER')) &&
      user.can('supplier.read'))
    AppDestination(
      icon: LucideIcons.truck,
      label: 'Fournisseurs',
      builder: (context, user) => SuppliersScreen(user: user),
    ),
  // `/users` : @Roles(ADMIN) + user.manage.
  if (user.hasRole('ADMIN') && user.can('user.manage'))
    AppDestination(
      icon: LucideIcons.shield,
      label: 'Utilisateurs',
      builder: (context, _) => const UsersScreen(),
    ),
  // `/audit-logs` : @Roles(ADMIN) + audit.read (lecture relue en base).
  if (user.hasRole('ADMIN') && user.can('audit.read'))
    AppDestination(
      icon: LucideIcons.history,
      label: 'Historique',
      builder: (context, _) => const AuditScreen(),
    ),
  AppDestination(
    icon: LucideIcons.user,
    label: 'Mon profil',
    builder: (context, user) => ProfileScreen(user: user),
  ),
];
