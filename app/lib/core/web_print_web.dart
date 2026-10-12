import 'dart:js_interop';
import 'dart:typed_data';

@JS('printPdfAtSize')
external JSPromise<JSAny?> _printPdfAtSize(JSUint8Array bytes, JSString name);

/// Imprime le PDF au format de sa page : `web/pdf_print.js` le dessine par
/// pdf.js (servi par le site) dans une page HTML qui impose le papier par
/// `@page { size }` — le plugin `printing` ignore le format dans le
/// navigateur, et son pdf.js (CDN + eval) est refusé par la CSP.
Future<void> printPdfInBrowser(Uint8List bytes, String name) =>
    _printPdfAtSize(bytes.toJS, name.toJS).toDart;
