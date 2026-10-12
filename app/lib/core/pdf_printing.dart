import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';

import '../data/local/local_settings_store.dart';
import 'providers.dart';
import 'web_print.dart';

/// Ce qu'on imprime, déduit du FORMAT du PDF (rendu par le serveur selon les
/// Paramètres) : chaque sorte a son imprimante sur un poste de caisse.
enum PaperKind {
  ticket('Tickets de caisse'),
  etiquette('Étiquettes'),
  document('Factures, bons et bordereaux');

  const PaperKind(this.title);
  final String title;
}

const _mm = 72 / 25.4;

/// Format de la 1re page du PDF (MediaBox, en points). pdfkit écrit les
/// dictionnaires de page en clair ; `null` si illisible.
PdfPageFormat? pdfFormatOf(Uint8List bytes) {
  final text = latin1.decode(bytes, allowInvalid: true);
  final match = RegExp(
    r'/MediaBox\s*\[\s*0\s+0\s+([\d.]+)\s+([\d.]+)\s*\]',
  ).firstMatch(text);
  if (match == null) return null;
  final width = double.tryParse(match.group(1)!);
  final height = double.tryParse(match.group(2)!);
  if (width == null || height == null) return null;
  return PdfPageFormat(width, height, marginAll: 0);
}

/// Ticket : la LARGEUR d'un rouleau de caisse (80 ou 58 mm, à 1 mm près) ;
/// autre petit format (≤ 150 mm) : étiquette ; sinon : document A4/A5.
PaperKind kindOf(PdfPageFormat format) {
  final widthMm = format.width / _mm;
  if ((widthMm - 80).abs() <= 1 || (widthMm - 58).abs() <= 1) {
    return PaperKind.ticket;
  }
  if (widthMm <= 150 && format.height / _mm <= 150) {
    return PaperKind.etiquette;
  }
  return PaperKind.document;
}

/// Poste de bureau : on peut choisir l'imprimante et imprimer sans dialogue.
bool get desktopPrinting =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.linux);

String _printerKey(PaperKind kind) => 'printer.${kind.name}';

/// Imprimante mémorisée sur CE poste pour une sorte de papier (`null` : aucune).
Future<String?> savedPrinter(LocalSettingsStore store, PaperKind kind) async {
  final url = await store.read(_printerKey(kind));
  return url == null || url.isEmpty ? null : url;
}

/// `null` : oublier l'imprimante (la boîte d'impression revient).
Future<void> savePrinter(
  LocalSettingsStore store,
  PaperKind kind,
  String? url,
) => store.write(_printerKey(kind), url ?? '');

/// Imprime un PDF À SON FORMAT (décision MEDMEDBEN du 2026-10-12 : plus de
/// ticket sur une page A4). Poste de bureau avec une imprimante choisie pour
/// cette sorte de papier : impression DIRECTE, sans dialogue. Sinon, la boîte
/// d'impression s'ouvre avec le bon format présélectionné (Windows règle le
/// papier de l'imprimante sur ce format).
Future<void> printPdf(Ref ref, Uint8List bytes, String name) async {
  final format = pdfFormatOf(bytes) ?? PdfPageFormat.a4;
  if (kIsWeb) {
    // Le plugin ignore `format` dans le navigateur : on imprime les pages en
    // images dans une page HTML qui impose le papier. 203 dpi : la finesse
    // d'une imprimante thermique.
    try {
      final pngs = [
        await for (final page in Printing.raster(bytes, dpi: 203))
          await page.toPng(),
      ];
      return await printPagesInBrowser(
        pngs,
        format.width / _mm,
        format.height / _mm,
        name,
      );
    } catch (_) {
      // pdf.js injoignable… : la boîte d'impression du PDF, comme avant.
    }
  }
  if (desktopPrinting) {
    final url = await savedPrinter(
      ref.read(localSettingsStoreProvider),
      kindOf(format),
    );
    if (url != null) {
      final done = await Printing.directPrintPdf(
        printer: Printer(url: url),
        onLayout: (_) async => bytes,
        name: name,
        format: format,
      );
      if (done) return;
    }
  }
  await Printing.layoutPdf(
    onLayout: (_) async => bytes,
    name: name,
    format: format,
    // Le PDF est déjà à sa taille : pas de remise en page par le dialogue.
    dynamicLayout: false,
  );
}
