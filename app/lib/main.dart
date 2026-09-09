import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/router/app_router.dart';
import 'ui/theme/app_theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProviderScope(child: GestionMagasinApp()));
}

class GestionMagasinApp extends ConsumerWidget {
  const GestionMagasinApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp.router(
      title: 'Gestion magasin',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark(),
      // Thème sombre imposé : c'est la direction artistique du produit,
      // pas une préférence système (spec §30).
      themeMode: ThemeMode.dark,
      routerConfig: ref.watch(routerProvider),
    );
  }
}
