// Lecteur de codes-barres du navigateur (mobile_scanner → zxing-wasm 3.1.3) :
// le moteur WebAssembly est servi par CE site, jamais par un CDN tiers
// (CSP stricte, page qui détient la session — audit du 2026-10-06).
ZXingWASM.setZXingModuleOverrides({
  locateFile: (path, prefix) =>
    path.endsWith('.wasm')
      ? new URL('zxing/' + path, document.baseURI).href
      : prefix + path,
});
