import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../../ui/widgets/screen_state.dart';
import '../../auth/data/auth_models.dart';
import 'scanned_product_sheet.dart';

/// La caméra n'est disponible que sur mobile : sur le poste, le code-barres se
/// lit à la DOUCHETTE (clavier) dans l'écran Vente — inutile d'ouvrir une
/// caméra qui n'existe pas.
bool get scannerSupported =>
    // Navigateur (iPhone) : caméra via mobile_scanner ; sa bibliothèque de
    // lecture est HÉBERGÉE par le site (web/zxing/), pas chargée d'un CDN.
    kIsWeb ||
    defaultTargetPlatform == TargetPlatform.android ||
    defaultTargetPlatform == TargetPlatform.iOS;

/// Premier code exploitable d'une capture (la caméra en émet plusieurs par
/// seconde) : le premier non vide, ou `null` s'il n'y a rien à lire.
String? firstBarcode(Iterable<String?> rawValues) => rawValues
    .whereType<String>()
    .map((v) => v.trim())
    .where((v) => v.isNotEmpty)
    .firstOrNull;

/// Scanner mobile (spec §27) : viser un code-barres, voir le produit, son prix
/// et ses stocks, puis agir (ajouter au panier). Le catalogue étant local, le
/// scan répond même sans réseau ; seuls les stocks exigent la connexion.
class ScanScreen extends ConsumerStatefulWidget {
  const ScanScreen({super.key, required this.user});

  final AuthUser user;

  @override
  ConsumerState<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends ConsumerState<ScanScreen>
    with WidgetsBindingObserver {
  /// Créé SEULEMENT là où la caméra existe : au poste, le construire
  /// ouvrirait un contrôleur sans implémentation native.
  MobileScannerController? _controller;
  String? _code;

  @override
  void initState() {
    super.initState();
    if (scannerSupported) {
      _controller = MobileScannerController(
        formats: const [
          BarcodeFormat.ean13,
          BarcodeFormat.ean8,
          BarcodeFormat.code128,
          BarcodeFormat.code39,
          // Pas de QR : un code produit est un code-barres 1D (règle 15).
        ],
      );
      // L'app passe en arrière-plan : la caméra s'arrête (voyant, batterie) et
      // reprend au retour — le paquet laisse ce soin à l'application.
      WidgetsBinding.instance.addObserver(this);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _controller;
    if (controller == null || _code != null) return;
    switch (state) {
      case AppLifecycleState.resumed:
        unawaited(controller.start());
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        unawaited(controller.stop());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  /// Un seul code à la fois : la caméra en émet plusieurs par seconde, on
  /// s'arrête au premier et on rend la main à l'utilisateur.
  void _onDetect(BarcodeCapture capture) {
    if (_code != null) return;
    final value = firstBarcode(capture.barcodes.map((b) => b.rawValue));
    if (value == null) return;
    // La caméra s'arrête pendant qu'on lit le résultat : elle ne filme pas la
    // salle de vente le temps que l'utilisateur décide.
    unawaited(_controller?.stop());
    setState(() => _code = value);
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null) {
      return const ScreenStateView(
        status: ScreenStatus.empty,
        title: 'Scan par la caméra du téléphone',
        message:
            'Sur ce poste, utilisez la douchette dans l’écran Vente : elle '
            'saisit le code puis « Entrée ».',
      );
    }
    final code = _code;
    return Stack(
      children: [
        MobileScanner(
          controller: controller,
          onDetect: _onDetect,
          // Sans ces états, le paquet affiche un écran noir et un message en
          // anglais, sans issue — le premier refus de permission suffirait à
          // bloquer le magasinier (spec §30 : Loading / Error sur tout écran).
          placeholderBuilder: (_) =>
              const ScreenStateView(status: ScreenStatus.loading),
          errorBuilder: (context, error) => ScreenStateView(
            status: ScreenStatus.error,
            title: 'Caméra indisponible',
            message: error.errorCode == MobileScannerErrorCode.permissionDenied
                ? 'L’accès à la caméra est refusé : autorisez-le dans les '
                      'réglages du téléphone, puis réessayez.'
                : 'La caméra n’a pas démarré. Fermez les autres applications '
                      'qui l’utilisent, puis réessayez.',
            onRetry: () => unawaited(controller.start()),
          ),
        ),
        if (code != null)
          Align(
            alignment: Alignment.bottomCenter,
            child: Material(
              color: Theme.of(context).colorScheme.surface,
              child: SafeArea(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ScannedProductSheet(
                      barcode: code,
                      user: widget.user,
                      onAddedToCart: () => _scanAgain('Ajouté au panier.'),
                    ),
                    TextButton(
                      onPressed: () => _scanAgain(null),
                      child: const Text('Scanner un autre code'),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  void _scanAgain(String? message) {
    setState(() => _code = null);
    unawaited(_controller?.start());
    if (message != null && mounted) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(message)));
    }
  }
}

/// Bouton caméra à poser dans un champ de recherche (spec §27) : sur
/// téléphone, il ouvre la caméra et rend le premier code lu à `onCode`. Au
/// poste (pas de caméra), il ne s'affiche pas — la douchette tape le code.
class CameraScanButton extends StatelessWidget {
  const CameraScanButton({super.key, required this.onCode});

  final void Function(String code) onCode;

  @override
  Widget build(BuildContext context) {
    if (!scannerSupported) return const SizedBox.shrink();
    return IconButton(
      tooltip: 'Scanner avec la caméra',
      icon: const Icon(Icons.qr_code_scanner, size: 20),
      onPressed: () async {
        final code = await scanWithCamera(context);
        if (code != null) onCode(code);
      },
    );
  }
}

/// Ouvre la caméra et rend le premier code-barres lu (`null` si abandon).
/// Téléphone seulement : vérifier `scannerSupported` avant.
Future<String?> scanWithCamera(BuildContext context) => Navigator.of(
  context,
).push<String>(MaterialPageRoute(builder: (_) => const _CameraScanPage()));

class _CameraScanPage extends StatefulWidget {
  const _CameraScanPage();

  @override
  State<_CameraScanPage> createState() => _CameraScanPageState();
}

class _CameraScanPageState extends State<_CameraScanPage> {
  final _controller = MobileScannerController(
    formats: const [
      BarcodeFormat.ean13,
      BarcodeFormat.ean8,
      BarcodeFormat.code128,
      BarcodeFormat.code39,
    ],
  );
  bool _done = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Viser le code-barres')),
      body: MobileScanner(
        controller: _controller,
        onDetect: (capture) {
          final value = firstBarcode(capture.barcodes.map((b) => b.rawValue));
          if (value == null || _done) return;
          _done = true;
          Navigator.of(context).pop(value);
        },
        placeholderBuilder: (_) =>
            const ScreenStateView(status: ScreenStatus.loading),
        errorBuilder: (context, error) => ScreenStateView(
          status: ScreenStatus.error,
          title: 'Caméra indisponible',
          message: error.errorCode == MobileScannerErrorCode.permissionDenied
              ? 'L’accès à la caméra est refusé : autorisez-le dans les '
                    'réglages du téléphone, puis réessayez.'
              : 'La caméra n’a pas démarré. Fermez les autres applications '
                    'qui l’utilisent, puis réessayez.',
          onRetry: () => unawaited(_controller.start()),
        ),
      ),
    );
  }
}
