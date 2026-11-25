// Page HORS CONNEXION (demande MEDMEDBEN du 2026-11-25) : au lieu du
// dinosaure du navigateur, offline.html quand internet est coupé ou que le
// serveur ne répond pas.
//
// Ce worker ne garde QUE offline.html. L'app elle-même vient TOUJOURS du
// serveur (réseau d'abord, rien d'autre en cache) : l'ancien worker de Flutter,
// qui servait une vieille version, ne peut pas revenir par ici (2026-10-29).
const CACHE = 'offline-page-v1';
const PAGE = 'offline.html';

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE).then((cache) => cache.add(new Request(PAGE, { cache: 'reload' }))),
  );
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil((async () => {
    for (const key of await caches.keys()) {
      if (key !== CACHE) await caches.delete(key);
    }
    await self.clients.claim();
  })());
});

self.addEventListener('fetch', (event) => {
  // Seulement l'ouverture d'une page ; tout le reste (app, API, photos) va
  // au réseau sans passer par ici.
  if (event.request.mode !== 'navigate') return;
  event.respondWith((async () => {
    try {
      const response = await fetch(event.request);
      // Serveur joint mais l'appli derrière est tombée (502 / 503 / 504).
      if (response.status >= 502 && response.status <= 504) {
        return (await caches.match(PAGE)) || response;
      }
      return response;
    } catch (_) {
      // Pas d'internet, ou serveur injoignable.
      return (await caches.match(PAGE)) || Response.error();
    }
  })());
});
