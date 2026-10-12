import 'dart:typed_data';

/// Hors navigateur : jamais appelé (`printPdf` passe par le plugin).
Future<void> printPagesInBrowser(
  List<Uint8List> pngs,
  double widthMm,
  double heightMm,
  String name,
) => throw UnsupportedError('Navigateur uniquement');
