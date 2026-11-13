import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
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

/// Pose de l'étiquette sur le papier RÉGLÉ dans le pilote : telle quelle si
/// les tailles concordent (à 1,5 mm près), sinon réduite pour tenir — tournée
/// d'un quart de tour si le pilote est en paysage et qu'elle y tient mieux.
({bool asIs, bool rotate}) labelPlacement(
  PdfPageFormat label,
  PdfPageFormat paper,
) {
  bool near(double a, double b) => (a - b).abs() <= 1.5 * _mm;
  if (near(label.width, paper.width) && near(label.height, paper.height)) {
    return (asIs: true, rotate: false);
  }
  double scale(double w, double h) =>
      math.min(paper.width / w, paper.height / h);
  final rotate =
      scale(label.height, label.width) >
      scale(label.width, label.height) * 1.05;
  return (asIs: false, rotate: rotate);
}

/// Retour terrain du 2026-11-13 : le pilote d'étiquettes (Smart, Xprinter)
/// IGNORE la taille sur mesure envoyée par le plugin et garde la sienne ;
/// imprimée à 100 %, l'étiquette débordait sur 2 ou 3 étiquettes. On imprime
/// donc sur le papier du pilote, et l'étiquette y est AJUSTÉE si besoin : elle
/// ne déborde jamais.
Future<Uint8List> fitLabelToPaper(Uint8List bytes, PdfPageFormat paper) async {
  final label = pdfFormatOf(bytes);
  if (label == null || paper.width <= 0 || paper.height <= 0) return bytes;
  final plan = labelPlacement(label, paper);
  if (plan.asIs) return bytes;
  final doc = pw.Document();
  final page = PdfPageFormat(paper.width, paper.height, marginAll: 0);
  // 406 dpi : deux fois la finesse d'une tête thermique (203 dpi).
  await for (final raster in Printing.raster(bytes, dpi: 406)) {
    final image = pw.Image(
      pw.MemoryImage(await raster.toPng()),
      width: label.width,
      height: label.height,
    );
    doc.addPage(
      pw.Page(
        pageFormat: page,
        build: (_) => pw.Center(
          child: pw.FittedBox(
            child: plan.rotate
                ? pw.Transform.rotateBox(angle: math.pi / 2, child: image)
                : image,
          ),
        ),
      ),
    );
  }
  return doc.save();
}

/// Pilote d'imprimante de BUREAU (jet d'encre, laser) ou générique. Posé sur
/// une imprimante d'étiquettes ou de tickets (thermique), il lui envoie un
/// langage qu'elle ne comprend pas : elle sort des lignes de caractères (un
/// « dump ») au lieu de l'étiquette — cas réel du 2026-11-10 : la file
/// « Xprinter » avec le pilote « Canon G3070 series ».
bool isOfficeDriver(String? driver) {
  final d = (driver ?? '').toLowerCase();
  if (d.isEmpty) return false;
  // Exceptions : gammes thermiques de marques « bureau ».
  const thermal = ['tm-', 'tm ', ' ql', 'ql-', 'td-', 'zebra', 'label'];
  if (thermal.any(d.contains)) return false;
  const office = [
    'canon',
    'hp ',
    'hewlett',
    'epson',
    'brother',
    'kyocera',
    'lexmark',
    'ricoh',
    'xerox',
    'samsung',
    'konica',
    'sharp',
    'pantum',
    'ipp class',
    'text only',
    'xps',
    'print to pdf',
    'onenote',
    'fax',
  ];
  return office.any(d.contains);
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
    try {
      return await printPdfInBrowser(bytes, name);
    } catch (_) {
      // pdf.js indisponible… : le PDF s'ouvre, comme avant.
    }
  }
  // Ticket : le papier RÉGLÉ dans l'imprimante (rouleau), jamais un format
  // sur mesure — beaucoup de pilotes thermiques le refusent et la tâche reste
  // « en erreur » dans la file (retour terrain du 2026-10-13).
  final roll = kindOf(format) == PaperKind.ticket;
  // Étiquette sur poste : le papier du PILOTE (sa taille d'étiquette), le PDF
  // ajusté dessus — jamais la taille sur mesure que le pilote ignore.
  final label = desktopPrinting && kindOf(format) == PaperKind.etiquette;
  Future<Uint8List> layout(PdfPageFormat paper) async =>
      label ? fitLabelToPaper(bytes, paper) : bytes;
  if (desktopPrinting) {
    final url = await savedPrinter(
      ref.read(localSettingsStoreProvider),
      kindOf(format),
    );
    if (url != null) {
      final done = await Printing.directPrintPdf(
        printer: Printer(url: url),
        onLayout: layout,
        name: name,
        format: format,
        usePrinterSettings: roll || label,
      );
      if (done) return;
    }
  }
  await Printing.layoutPdf(
    onLayout: layout,
    name: name,
    format: format,
    usePrinterSettings: roll || label,
    // Le PDF est déjà à sa taille : pas de remise en page par le dialogue.
    dynamicLayout: false,
  );
}
