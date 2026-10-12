import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gestion_magasin/core/pdf_printing.dart';
import 'package:pdf/pdf.dart';

const _mm = 72 / 25.4;

/// En-tête minimal d'une page pdfkit : le dictionnaire est écrit en clair.
Uint8List _pdf(double widthMm, double heightMm) => Uint8List.fromList(
  latin1.encode(
    '%PDF-1.3\n3 0 obj\n<<\n/Type /Page\n/MediaBox [0 0 '
    '${(widthMm * _mm).toStringAsFixed(6)} ${(heightMm * _mm).toStringAsFixed(6)}]\n>>\n',
  ),
);

void main() {
  // Décision MEDMEDBEN du 2026-10-12 : imprimer AU FORMAT du document (plus
  // de ticket sur une page A4), sur l'imprimante de sa sorte de papier.
  test('format lu dans le PDF, sorte de papier déduite', () {
    final ticket80 = pdfFormatOf(_pdf(80, 210))!;
    expect(ticket80.width / _mm, closeTo(80, 0.01));
    expect(ticket80.height / _mm, closeTo(210, 0.01));
    expect(kindOf(ticket80), PaperKind.ticket);
    expect(kindOf(pdfFormatOf(_pdf(58, 90))!), PaperKind.ticket);
    // Étiquette en portrait : PAS un ticket, malgré sa forme.
    expect(kindOf(pdfFormatOf(_pdf(35, 45))!), PaperKind.etiquette);
    expect(kindOf(pdfFormatOf(_pdf(60, 40))!), PaperKind.etiquette);
    expect(kindOf(PdfPageFormat.a5), PaperKind.document);
    expect(kindOf(PdfPageFormat.a4), PaperKind.document);
    expect(pdfFormatOf(Uint8List.fromList([1, 2, 3])), isNull);
  });
}
