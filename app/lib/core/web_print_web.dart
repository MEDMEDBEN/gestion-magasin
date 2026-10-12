import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

const _frameId = 'web-print-frame';

/// Imprime des pages (PNG) dans une page HTML qui IMPOSE le papier par
/// `@page { size }` : Chrome/Edge règlent alors la boîte d'impression sur ce
/// format. Imprimé tel quel, le PDF suivait le papier par défaut de
/// l'imprimante — un ticket sortait sur un A4 (retour terrain du 2026-10-12).
Future<void> printPagesInBrowser(
  List<Uint8List> pngs,
  double widthMm,
  double heightMm,
  String name,
) async {
  final w = widthMm.toStringAsFixed(2);
  final h = heightMm.toStringAsFixed(2);
  final pages = [
    for (final png in pngs)
      '<img src="data:image/png;base64,${base64Encode(png)}">',
  ].join();
  final html =
      '<!doctype html><html><head><meta charset="utf-8">'
      '<title>${const HtmlEscape().convert(name)}</title><style>'
      '@page{size:${w}mm ${h}mm;margin:0}'
      'html,body{margin:0;padding:0}'
      // Un rien sous la hauteur : pas de page blanche ajoutée par l'arrondi.
      'img{display:block;width:${w}mm;height:calc(${h}mm - 0.3mm);'
      'break-after:page}img:last-child{break-after:auto}'
      '</style></head><body>$pages</body></html>';

  final doc = web.window.document;
  doc.getElementById(_frameId)?.remove();
  final frame = web.HTMLIFrameElement()
    ..id = _frameId
    ..setAttribute(
      'style',
      'position:fixed;left:0;top:0;width:0;height:0;border:0;visibility:hidden',
    );
  final loaded = frame.onLoad.first;
  frame.srcdoc = html.toJS;
  doc.body!.append(frame);
  await loaded;
  frame.contentWindow!.print();
}
