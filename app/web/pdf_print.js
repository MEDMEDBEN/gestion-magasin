// Impression d'un PDF AU FORMAT de sa page (retour terrain du 2026-10-12 :
// imprimé tel quel par la visionneuse du navigateur, un ticket sortait sur un
// A4). Les pages sont dessinées en images par pdf.js — servi par ce site, sans
// eval : la CSP de web.nginx.conf l'interdit — puis imprimées dans une page
// HTML dont `@page { size }` impose le papier à Chrome/Edge.
(function () {
  var lib;
  var FRAME_ID = 'pdf-print-frame';

  async function pdfjs() {
    if (!lib) {
      lib = await import('./pdfjs/pdf.min.mjs');
      lib.GlobalWorkerOptions.workerSrc = 'pdfjs/pdf.worker.min.mjs';
    }
    return lib;
  }

  function escapeHtml(s) {
    return s.replace(/[&<>"]/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c];
    });
  }

  // 203 dpi : la finesse d'une imprimante thermique.
  var SCALE = 203 / 72;
  var MM = 72 / 25.4;

  window.printPdfAtSize = async function (bytes, name) {
    var pdf = await (await pdfjs()).getDocument({
      data: bytes,
      isEvalSupported: false,
      standardFontDataUrl: 'pdfjs/standard_fonts/',
    }).promise;
    var images = [];
    var width = 0;
    var height = 0;
    try {
      for (var i = 1; i <= pdf.numPages; i++) {
        var page = await pdf.getPage(i);
        if (i === 1) {
          var size = page.getViewport({ scale: 1 });
          width = size.width / MM;
          height = size.height / MM;
        }
        var viewport = page.getViewport({ scale: SCALE });
        var canvas = document.createElement('canvas');
        canvas.width = Math.ceil(viewport.width);
        canvas.height = Math.ceil(viewport.height);
        await page.render({
          canvas: canvas,
          canvasContext: canvas.getContext('2d'),
          viewport: viewport,
        }).promise;
        images.push('<img src="' + canvas.toDataURL('image/png') + '">');
      }
    } finally {
      pdf.destroy();
    }
    var w = width.toFixed(2);
    var h = height.toFixed(2);
    // Ticket de caisse (rouleau 80 / 58 mm) : AUCUN format imposé — beaucoup
    // de pilotes thermiques refusent un papier sur mesure et laissent la tâche
    // « en erreur » dans la file (retour terrain du 2026-10-13). Le ticket part
    // sur le papier réglé dans l'imprimante (rouleau), à sa largeur exacte.
    var roll = Math.abs(width - 80) <= 1 || Math.abs(width - 58) <= 1;
    var html =
      '<!doctype html><html><head><meta charset="utf-8"><title>' +
      escapeHtml(name) +
      '</title><style>' +
      (roll
        ? '@page{margin:0}'
        : '@page{size:' + w + 'mm ' + h + 'mm;margin:0}') +
      'html,body{margin:0;padding:0}' +
      // Un rien sous la hauteur : pas de page blanche ajoutée par l'arrondi.
      'img{display:block;width:' + w + 'mm;' +
      (roll ? 'height:auto;' : 'height:calc(' + h + 'mm - 0.3mm);') +
      'break-after:page}img:last-child{break-after:auto}' +
      '</style></head><body>' + images.join('') + '</body></html>';

    var old = document.getElementById(FRAME_ID);
    if (old) old.remove();
    var frame = document.createElement('iframe');
    frame.id = FRAME_ID;
    frame.setAttribute(
      'style',
      'position:fixed;left:0;top:0;width:0;height:0;border:0;visibility:hidden'
    );
    await new Promise(function (resolve) {
      frame.onload = resolve;
      frame.srcdoc = html;
      document.body.append(frame);
    });
    frame.contentWindow.focus();
    frame.contentWindow.print();
  };
})();
