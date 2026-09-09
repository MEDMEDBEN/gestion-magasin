# État d'avancement

> Les deux devs travaillent à des heures différentes, jamais en simultané — ce fichier EST le relais entre vous deux.
> Règle stricte : `git pull` + lire ce fichier en entier AVANT de coder. Le mettre à jour + `git push` avant de fermer la session.
> Au retour, dire simplement "lis tasks.md et continue" plutôt que de reprendre l'historique complet.

## Phase actuelle
`Phase 0 — Fondation` (en cours — étapes 1 et 2 terminées : schéma, OpenAPI, auth, seed)

## Dernier relais
- Date : 2026-09-09
- Qui a travaillé : Dev A (backend & data)
- Ce qui a été fait : **étape 2 de la Phase 0 — contrat OpenAPI + auth + seed**.
  (L'étape 1 — schéma Prisma + migration — reste validée et n'a pas été retouchée.)

### 1. Contrat OpenAPI
- `@nestjs/swagger` actif, doc servie sur **`/docs`** (préfixe global `api` pour les routes).
- **46 endpoints, 57 schémas DTO, 19 tags** couvrant tout le P0.
- Squelette figé (routes + DTO + guards + doc) pour les features non encore développées :
  chaque route répond **501 `NOT_IMPLEMENTED`** — jamais une 404 trompeuse. Voir
  `backend/src/common/api-contract.module.ts`.
- Conventions respectées : pagination `{ data, meta: { page, limit, total } }`
  (`common/dto/pagination.dto.ts`), erreurs `{ statusCode, message, error, code? }`
  (`common/http-exception.filter.ts`), codes métier stables (`common/error-codes.ts`).

### 2. Auth (implémentée et testée)
- Création de compte **par l'admin uniquement**, pas d'inscription publique.
- Login par **email OU téléphone**, argon2id ; access JWT **15 min**.
- Refresh **opaque** (256 bits), stocké **en SHA-256** dans `RefreshToken`, **90 j glissants**,
  **rotation à chaque appel**, révocable. Rejouer un token révoqué = vol présumé →
  **toutes** les sessions de l'utilisateur sont fermées.
- `mustChangePassword` : verrouille toute l'API sauf `change-password` / `logout`.
- Guards **globaux** : `JwtAccessGuard` puis `RolesGuard`, + `@Roles` / `@RequirePermissions`.
- Endpoints : `POST /api/auth/login|refresh|change-password|logout`, `GET /api/auth/me`,
  et la gestion de comptes admin `POST|GET /api/users`, `PATCH /api/users/:id`,
  `POST /api/users/:id/reset-password|revoke-sessions`.

### 3. Seed (`backend/prisma/seed.ts`, `npm run seed`)
Idempotent : 38 permissions, 3 rôles, 3 locations, 2 tarifs, 2 taux de TVA, 1 admin.

### Preuves réelles (sorties collées)

Tests unitaires — argon2, JWT, RolesGuard :
```
$ npm test
PASS src/common/roles.guard.spec.ts
PASS src/common/jwt-access.guard.spec.ts
PASS src/auth/auth.service.spec.ts
Test Suites: 3 passed, 3 total
Tests:       21 passed, 21 total
```

Tests d'intégration — sur la vraie base PostgreSQL :
```
$ npm run test:e2e
PASS test/auth.e2e-spec.ts
  √ refuse un mot de passe incorrect
  √ donne la même erreur pour un compte inexistant (pas d'énumération)
  √ login puis accès à une route protégée
  √ refuse une route protégée sans token
  √ le refresh fait la ROTATION : l'ancien token devient inutilisable
  √ un refresh révoqué par logout est rejeté
  √ un refresh inconnu est rejeté
  √ un VENDEUR est bloqué sur une route ADMIN
  √ un ADMIN accède à la route ADMIN
  √ mustChangePassword verrouille tout sauf le changement de mot de passe
  √ un compte désactivé ne peut plus se connecter
  √ rejette un payload avec un champ inconnu (whitelist stricte)
  √ un endpoint au contrat figé répond 501 NOT_IMPLEMENTED, pas 404
  √ refuse de réutiliser le mot de passe courant au changement
  √ refuse un code de permission inconnu (400, pas 500)
  √ un VENDEUR n'a aucun accès aux fournisseurs (matrice validée)
  √ la sonde /api/health est publique
Test Suites: 1 passed, 1 total
Tests:       17 passed, 17 total
```

Seed (2ᵉ exécution = idempotent, aucun doublon) :
```
$ npm run seed
  ✔ 38 permissions
  ✔ rôle ADMIN — 38 permissions
  ✔ rôle VENDEUR — 16 permissions
  ✔ rôle MAGASINIER — 15 permissions
  ✔ emplacements MAGASIN / DEPOT / TRANSIT
  ✔ tarifs DETAIL/GROS + TVA 19 %/0 %
  ✔ admin admin@magasin.dz déjà présent — mot de passe inchangé
```

Serveur réellement démarré :
```
$ node dist/main.js
$ curl http://localhost:3000/api/health
{"status":"ok","timestamp":"2026-09-09T03:37:21.193Z"}

$ curl -o /dev/null -w "%{http_code}" http://localhost:3000/docs
200

$ curl http://localhost:3000/api/users          # sans token
{"statusCode":401,"message":"Access token manquant","error":"UNAUTHORIZED","code":"ACCESS_TOKEN_MISSING"}
```

### DATABASE_URL — vérifié, et un piège corrigé
**Confirmé : `DATABASE_URL` est bien câblé, mais il l'est à DEUX endroits distincts.**
Le `datasource` du schéma n'a volontairement pas de ligne `url` : en **Prisma 7**, l'URL vit dans
`prisma7.config.ts` — mais **ce fichier ne sert que la CLI**. Au runtime, Prisma 7 exige un
**driver adapter** ; sans lui, `PrismaClient` lève
« *PrismaClient was instantiated without any options. A driver adapter is required* ».
`PrismaService` construit donc explicitement `new PrismaPg({ connectionString })` à partir de
`ConfigService.get('DATABASE_URL')`, et **refuse de démarrer** si la variable est absente.

> À retenir : `prisma7.config.ts` = CLI · `PrismaService` = runtime. Les deux lisent `backend/.env`.

### Autres corrections d'infrastructure faites au passage
- **Client Prisma déplacé** de `backend/generated/` vers `backend/src/generated/` : situé hors de
  `src`, il décalait la sortie du build en `dist/src/main.js` et cassait `npm run start:prod`.
- **`incremental` retiré de `tsconfig.json`** : combiné au `deleteOutDir` de Nest, tsc croyait le
  build à jour alors que `dist/` venait d'être supprimé → build silencieusement vide.
  `dist/main.js` est désormais produit de façon reproductible (vérifié sur deux builds successifs).
- ⚠️ **Reste à supprimer à la main** : l'ancien dossier `backend/generated/` (mort, gitignoré) —
  la suppression a été refusée par les permissions de l'agent.

### Audit `security-reviewer` — passé, corrections appliquées
Aucun problème critique. Corrigé dans la foulée :
- **rate limiting** (`@nestjs/throttler`) : 10 tentatives / 15 min sur `/auth/login`, 30 sur
  `/auth/refresh` — surchargeable par `AUTH_LOGIN_LIMIT` / `AUTH_REFRESH_LIMIT` ;
- **rotation du refresh rendue atomique** (`updateMany` avec `revokedAt: null` dans le WHERE) :
  deux refresh concurrents ne peuvent plus produire chacun une session valide ;
- **anti-énumération temporelle** : vérification argon2 factice quand le compte n'existe pas,
  pour que la réponse prenne le même temps ;
- **changement de mot de passe** : réutilisation du mot de passe courant refusée — sinon le
  verrou `mustChangePassword` se contournait en resoumettant le mot de passe temporaire ;
- **dernier admin protégé** : impossible de retirer le rôle ADMIN ou de désactiver le dernier
  administrateur actif ;
- **`extraPermissions` validé** contre le catalogue (400 métier au lieu d'une 500 Prisma) ;
- **Swagger fermé en production** (`NODE_ENV === 'production'`) ;
- **codes d'erreur dédiés** `ACCESS_TOKEN_MISSING` / `ACCESS_TOKEN_INVALID` — un access token
  manquant renvoyait un code de *refresh*, trompeur pour le client.

**Dette assumée, à traiter à sa feature** : les actions sensibles de gestion de comptes (création,
changement de rôles/permissions, reset de mot de passe, révocation) **n'écrivent pas encore dans
`AuditLog`**. C'est la feature P0 n°11 « Historique / audit » — à faire dans la **même transaction**
que la mutation, avec l'acteur pris via `@CurrentUser()`.

### Matrice de permissions — validée et appliquée
`docs/permissions.md` est passé de « brouillon à valider » à **« VALIDÉE le 2026-09-09 »**, avec les
5 règles fermes (prix/tarifs admin only · pas de remise libre · crédit plafonné par
`Customer.creditLimit`, défaut 0 · commandes fournisseurs admin+magasinier · confirmation admin seul).
Traduction technique unique : `backend/src/common/permissions.ts`, lu par le seed **et** par les guards.

**Une ambiguïté a été tranchée** : la ligne « Gérer fournisseurs » ne distinguait pas lecture et
gestion. Elle est scindée en deux ; le **vendeur n'a aucun accès aux fournisseurs**, et
`supplier.read` a été retiré de son rôle. Un test e2e verrouille cette décision.

> ⚠️ Le seed fait autorité sur les permissions des rôles (il utilise `set`). Après toute
> modification de `permissions.ts`, **relancer `npm run seed`** — sinon la base garde l'ancien jeu
> et les tokens émis restent périmés (c'est exactement ce qui a fait échouer un test au premier essai).

**Garde-fou structurel** : une route authentifiée **sans `@Roles` explicite est refusée**
(`FORBIDDEN_ROLE`). Oublier le décorateur ferme la route au lieu de l'ouvrir — la règle 1 de
`CLAUDE.md` est ainsi rendue mécanique, et couverte par un test unitaire.

- État exact du code : `backend/` compile, **38 tests passent**, le serveur démarre, `/docs` répond.
  Auth **complète et testée**. Contrat P0 **figé** mais features **non implémentées** (501).
  `app/` (Flutter) n'existe toujours pas.
- Bloqué sur : rien.
- **Prochaine étape précise** (étape 3 de la Phase 0) : **socle de synchronisation offline**, dans
  `backend/src/sync/` — appliquer `docs/context.md` à la lettre.
  1. `POST /api/sync` : reçoit un **lot** de mutations triées par timestamp appareil
     (`clientMutationId`, `deviceId`, `operationType`, `payload`, `deviceTimestamp`).
  2. **Idempotence** : dédup sur `SyncMutation.clientMutationId` (déjà `@unique` en base). Une
     mutation déjà vue **n'est pas rejouée** — on renvoie le résultat mémorisé (`status`,
     `resultEntityId`).
  3. Par mutation, **dans une transaction** : vérifier le `clientMutationId`, puis les
     **permissions** (les mêmes qu'en ligne), puis la règle métier.
  4. **Validation avec REJET** : anti-stock-négatif (sauf `Product.allowBackorder`), produit actif,
     montants cohérents. Un rejet n'applique **rien** et renvoie `REJETEE` + motif lisible
     (`ErrorCode.SYNC_MUTATION_REJECTED`).
  5. Réponse par mutation : `CONFIRMEE` + état serveur, ou `REJETEE` + motif — pour que le client
     puisse réconcilier (`docs/context.md` §6).
  6. Tests obligatoires : rejouer deux fois le même `clientMutationId` n'applique la mutation
     qu'une seule fois ; une mutation qui rendrait le stock négatif est rejetée sans effet de bord.

  > Ensuite seulement : étape 4 = structure Flutter de base (`app/`).
  > Rappel : **ne commencer aucune feature métier P0** tant que la Phase 0 n'est pas terminée.

## Avancement par feature

| Feature | Statut | Backend | Frontend | Tests | Sécurité |
|---|---|---|---|---|---|
| Phase 0 — Fondation (schéma + OpenAPI + auth + socle sync) | 🟡 En cours | 🟢 Schéma · 🟢 OpenAPI · 🟢 Auth · 🔴 Socle sync | — | 🟢 21 unit + 17 e2e | 🟢 Audit passé |
| Auth + rôles/permissions | 🟢 Backend terminé | 🟢 Login/refresh/logout/guards/seed | 🔴 À faire | 🟢 38 tests | 🟢 Audit passé |
| Produits + catégories + emplacements | 🔴 Non commencé | 🟡 Contrat figé (501) | — | — | — |
| Stock + mouvements | 🔴 Non commencé | 🟡 Contrat figé (501) | — | — | — |
| Ventes (tarifs, TVA/facture, caisse) + dettes clients + paiements | 🔴 Non commencé | 🟡 Contrat figé (501) | — | — | — |
| Fournisseurs + clients + dettes fournisseurs | 🔴 Non commencé | 🟡 Contrat figé (501) | — | — | — |
| Achats | 🔴 Non commencé | 🟡 Contrat figé (501) | — | — | — |
| Réceptions (dont partielles) | 🔴 Non commencé | 🟡 Contrat figé (501) | — | — | — |
| Transferts magasin↔dépôt | 🔴 Non commencé | 🟡 Contrat figé (501) | — | — | — |
| Inventaire + tournant | 🔴 Non commencé | 🟡 Contrat figé (501) | — | — | — |
| Planning hebdomadaire | 🔴 Non commencé | 🟡 Contrat figé (501) | — | — | — |
| Historique/audit | 🔴 Non commencé | 🟡 Contrat figé (501) | — | — | — |
| Génération PDF/Excel, devis, étiquettes code-barres (P1) | 🔴 Non commencé | — | — | — | — |
| Socle offline/sync appliqué au P0 | 🔴 Non commencé | — | — | — | — |

Légende : 🔴 non commencé · 🟡 en cours · 🟢 terminé et prouvé

## Décisions en attente
- ~~Matrice de permissions CRUD détaillée par entité~~ → **VALIDÉE le 2026-09-09** (`docs/permissions.md`).
- Confirmer les canaux de notification temps réel (WebSocket) au moment de la feature Notifications (P1).
