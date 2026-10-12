import 'dart:typed_data';

/// Hors navigateur : jamais appelé (`printPdf` passe par le plugin).
Future<void> printPdfInBrowser(Uint8List bytes, String name) =>
    throw UnsupportedError('Navigateur uniquement');
