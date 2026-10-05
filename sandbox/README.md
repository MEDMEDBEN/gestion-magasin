# Sandbox — fonctionnalités retirées, gardées pour réutilisation

Chaque dossier contient une fonctionnalité **retirée de ce projet** mais conservée pour être
réutilisée ailleurs. Rien ici n'est compilé ni testé par le projet (le backend compile `backend/`,
l'app compile `app/`).

| Dossier | Retirée le | Tag git de l'état d'avant |
|---|---|---|
| [`cheques/`](cheques/README.md) | 2026-10-05 | `avant-retrait-cheques` |
| [`tva/`](tva/README.md) | 2026-10-05 | `avant-retrait-tva` |

Règle : la **base de données n'est jamais touchée** par un retrait. Les tables et colonnes
restent en place (aucune migration destructive) ; seul le code qui s'en servait est parti.
