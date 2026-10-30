// Ancien « service worker » de Flutter (cache hors ligne) RETIRÉ le 2026-10-29 :
// il servait l'ancienne version de l'app avant la nouvelle, et Safari (iPhone,
// écran d'accueil) la gardait des jours. Ce fichier le remplace chez ceux qui
// l'ont encore : il vide ses caches, se désinscrit et recharge la page.
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (event) => {
  event.waitUntil((async () => {
    const keys = await caches.keys();
    await Promise.all(keys.map((key) => caches.delete(key)));
    await self.registration.unregister();
    const pages = await self.clients.matchAll({ type: 'window' });
    for (const page of pages) page.navigate(page.url);
  })());
});
