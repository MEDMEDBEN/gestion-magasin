import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gestion_magasin/core/providers.dart';
import 'package:gestion_magasin/data/local/app_database.dart';
import 'package:gestion_magasin/features/auth/application/auth_controller.dart';
import 'package:gestion_magasin/features/auth/data/auth_models.dart';
import 'package:gestion_magasin/features/auth/presentation/change_password_screen.dart';
import 'package:gestion_magasin/features/auth/presentation/login_screen.dart';
import 'package:gestion_magasin/features/users/data/users_api.dart';
import 'package:gestion_magasin/ui/adaptive_shell.dart';
import 'package:gestion_magasin/ui/breakpoints.dart';
import 'package:gestion_magasin/ui/theme/app_theme.dart';

import '../support/fakes.dart';

/// OUTIL (opt-in) de vérification visuelle : rend les vrais écrans avec les
/// vraies polices (Archivo, Lucide) et des données fictives, en PNG, pour
/// relire le design AMPÈRE sur toutes les tailles sans appareil sous la main.
///
///   flutter test test/tools/screen_captures_test.dart --dart-define=CAPTURE_OUT=/chemin/dossier
///
/// Sans `CAPTURE_OUT`, ces tests sont IGNORÉS : `flutter test` ne produit rien.
const out = String.fromEnvironment('CAPTURE_OUT');

class _SignedIn extends AuthController {
  _SignedIn(this.user);
  final AuthUser user;
  @override
  Future<AuthState> build() async => AuthSignedIn(user);
}

class _SignedOut extends AuthController {
  @override
  Future<AuthState> build() async => const AuthSignedOut();
}

final _users = [
  managedUser(id: 'me', fullName: 'Radhi Badache', email: 'admin@magasin.dz', roles: const ['ADMIN'], lastLoginAt: DateTime(2026, 9, 11, 9, 2)),
  managedUser(id: 'u2', fullName: 'Amine Benali', email: 'amine@magasin.dz', roles: const ['VENDEUR'], lastLoginAt: DateTime(2026, 9, 10, 17, 45)),
  managedUser(id: 'u3', fullName: 'Karim Saidi', email: null, phone: '+213555123456', roles: const ['MAGASINIER', 'VENDEUR'], lastLoginAt: DateTime(2026, 9, 11, 7, 58)),
  managedUser(id: 'u4', fullName: 'Nadia Kaci', email: 'nadia@magasin.dz', roles: const ['VENDEUR'], mustChangePassword: true),
  managedUser(id: 'u5', fullName: 'Yacine Ouali', email: 'yacine@magasin.dz', roles: const ['MAGASINIER'], isActive: false, lastLoginAt: DateTime(2026, 8, 28, 16, 10)),
];

Future<void> _loadFonts() async {
  final archivo = FontLoader('Archivo')..addFont(rootBundle.load('fonts/Archivo-Variable.ttf'));
  final lucide = FontLoader('packages/lucide_icons_flutter/Lucide')
    ..addFont(rootBundle.load('packages/lucide_icons_flutter/assets/lucide.ttf'));
  await Future.wait([archivo.load(), lucide.load()]);
}

Future<void> _capture(
  WidgetTester tester, {
  required String name,
  required Size size,
  required Widget home,
  bool dark = true,
  AuthController Function()? auth,
  int foreignPending = 0,
  Future<void> Function(WidgetTester)? interact,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final db = AppDatabase.forTesting();
  final key = GlobalKey();

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authControllerProvider.overrideWith(auth ?? () => _SignedIn(authUser(id: 'me', fullName: 'Radhi Badache'))),
        appDatabaseProvider.overrideWithValue(db),
        usersApiProvider.overrideWithValue(FakeUsersApi(users: _users)),
        currentUserIdProvider.overrideWithValue('me'),
        pendingMutationsCountProvider.overrideWith((ref) => Stream.value(0)),
        foreignPendingMutationsCountProvider.overrideWith((ref) => Stream.value(foreignPending)),
        rejectedMutationsProvider.overrideWith((ref) => Stream.value(const [])),
      ],
      child: RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          builder: (context, child) => Theme(
            data: isDesktopWidth(MediaQuery.sizeOf(context).width)
                ? AppTheme.desktop(dark: dark)
                : AppTheme.mobile(dark: dark),
            child: child!,
          ),
          home: home,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  if (interact != null) {
    await interact(tester);
    await tester.pumpAndSettle();
  }

  await tester.runAsync(() async {
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    File('$out/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
  });
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.runAsync(db.close);
}

void main() {
  setUpAll(_loadFonts);
  const skip = out == '';

  testWidgets('01 login desktop sombre', skip: skip, (t) => _capture(t, name: '01_login_desktop_sombre', size: const Size(1440, 900), home: const LoginScreen(), auth: _SignedOut.new));
  testWidgets('02 login mobile clair', skip: skip, (t) => _capture(t, name: '02_login_mobile_clair', size: const Size(390, 844), home: const LoginScreen(), auth: _SignedOut.new, dark: false));
  testWidgets('03 mot de passe force mobile', skip: skip, (t) => _capture(t, name: '03_mdp_force_mobile', size: const Size(390, 844), home: const ChangePasswordScreen()));
  testWidgets('04 utilisateurs desktop sombre', skip: skip, (t) => _capture(t, name: '04_utilisateurs_desktop_sombre', size: const Size(1440, 900), home: const AdaptiveShell(),
      interact: (t) async => t.tap(find.text('Utilisateurs'))));
  testWidgets('05 utilisateurs desktop clair', skip: skip, (t) => _capture(t, name: '05_utilisateurs_desktop_clair', size: const Size(1440, 900), home: const AdaptiveShell(), dark: false,
      interact: (t) async => t.tap(find.text('Utilisateurs'))));
  testWidgets('06 formulaire panneau desktop', skip: skip, (t) => _capture(t, name: '06_formulaire_panneau_desktop', size: const Size(1440, 900), home: const AdaptiveShell(),
      interact: (t) async {
        await t.tap(find.text('Utilisateurs'));
        await t.pumpAndSettle();
        await t.tap(find.text('Karim Saidi'));
      }));
  testWidgets('07 tablette rail', skip: skip, (t) => _capture(t, name: '07_tablette_rail', size: const Size(1024, 768), home: const AdaptiveShell(),
      interact: (t) async => t.tap(find.byTooltip('Utilisateurs'))));
  testWidgets('08 utilisateurs mobile sombre', skip: skip, (t) => _capture(t, name: '08_utilisateurs_mobile_sombre', size: const Size(390, 844), home: const AdaptiveShell(),
      interact: (t) async => t.tap(find.text('Utilisateurs'))));
  testWidgets('09 formulaire plein ecran mobile', skip: skip, (t) => _capture(t, name: '09_formulaire_mobile', size: const Size(390, 844), home: const AdaptiveShell(),
      interact: (t) async {
        await t.tap(find.text('Utilisateurs'));
        await t.pumpAndSettle();
        await t.tap(find.text('Nouveau'));
      }));
  testWidgets('10 confirmation danger desktop', skip: skip, (t) => _capture(t, name: '10_confirmation_danger', size: const Size(1440, 900), home: const AdaptiveShell(),
      interact: (t) async {
        await t.tap(find.text('Utilisateurs'));
        await t.pumpAndSettle();
        await t.tap(find.byTooltip('Actions').at(1));
        await t.pumpAndSettle();
        await t.tap(find.text('Désactiver'));
      }));
  testWidgets('11 profil mobile', skip: skip, (t) => _capture(t, name: '11_profil_mobile', size: const Size(390, 844), home: const AdaptiveShell(), foreignPending: 2,
      interact: (t) async => t.tap(find.text('Mon profil'))));
}
