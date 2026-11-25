// Inscrit le worker de la page hors connexion (offline-sw.js). Fichier à part :
// la politique de sécurité du site interdit les scripts écrits dans la page.
if ('serviceWorker' in navigator) {
  navigator.serviceWorker.register('offline-sw.js').catch(() => {});
}
