# État d'avancement

> Les deux devs travaillent à des heures différentes, jamais en simultané — ce fichier EST le relais entre vous deux.
> Règle stricte : `git pull` + lire ce fichier en entier AVANT de coder. Le mettre à jour + `git push` avant de fermer la session.
> Au retour, dire simplement "lis tasks.md et continue" plutôt que de reprendre l'historique complet.

## Phase actuelle
`Phase 0 — Fondation` (étapes 1, 2 et 3 terminées : schéma, OpenAPI, auth, seed, **socle de sync**)
Reste **l'étape 4 — structure Flutter de base** pour clore la Phase 0.

## Dernier relais
- Date : 2026-09-09
- Qui a travaillé : Dev A (backend & data)
- Ce qui a été fait : **étape 3 de la Phase 0 — socle de synchronisation offline** (`backend/src/sync/`),
  application de `docs/context.md` §3-§5. Les étapes 1 et 2 n'ont pas été retouchées (sauf une colonne
  ajoutée, voir « Migration » plus bas).

### 1. `POST /api/sync` — un lot de mutations hors-ligne, idempotent

Requête : `{ mutations: [ { clientMutationId, deviceId, operationType, payload, deviceTimestamp } ] }`
(200 mutations max — le `MAX_PENDING_MUTATIONS` de `docs/context.md`).
Réponse : `{ serverTime, results: [ { clientMutationId, status, entityId?, code?, reason?, serverState?, alreadyProcessed } ] }`.

**Trois issues possibles, deux seulement sont mémorisées :**

| Statut | Sens | Mémorisé ? | Ce que fait le client |
|---|---|---|---|
| `CONFIRMEE` | appliquée | ✅ | retire la mutation de la file |
| `REJETEE` | refusée définitivement (permission, payload, règle métier) | ✅ | affiche le motif, exige une action (annuler / corriger = **nouvelle** mutation) |
| `NON_TRAITEE` | rien n'a été tenté (panne technique, ou feature pas encore livrée) | ❌ | **garde** la mutation en file et la renverra telle quelle |

Le client réagit toujours au **`code`** (`STOCK_NEGATIVE`, `FORBIDDEN_PERMISSION`, `VALIDATION_FAILED`,
`NOT_FOUND`, `NOT_IMPLEMENTED`, `SYNC_RETRY_LATER`), jamais au texte français de `reason`.

Garanties tenues, dans l'ordre, pour chaque mutation :
1. **Idempotence** — `clientMutationId` déjà vu ⇒ résultat mémorisé renvoyé, rien n'est rejoué.
2. **Rôle PUIS permissions** — exactement ce qu'exige la route en ligne équivalente, portés par le
   handler de l'opération et non par la route (les 3 rôles synchronisent, chacun ses opérations).
   Les deux contrôles sont nécessaires : sans le rôle, un membre à qui l'admin accorde une
   permission « à la carte » serait refusé en ligne mais accepté hors-ligne.
3. **Validation** du payload contre un DTO `class-validator` dédié (whitelist stricte).
4. **Règle métier** dans **une** transaction : mouvement + projection + audit, ou rien.

Le lot est rejoué dans l'ordre du **timestamp appareil** (retrié côté serveur), et s'arrête à la
première panne technique pour ne pas casser cet ordre. Un rejet métier, lui, n'arrête rien.

### 2. Le socle stock partagé — `backend/src/stock/stock-ledger.service.ts`

Le contrat de sync exige l'anti-stock-négatif ; il fallait donc écrire la règle 2 de `CLAUDE.md`
pour de bon. Elle vit dans **un seul** service, sans route, réutilisable tel quel par la feature P0 n°3
« Stock », puis par ventes / réceptions / transferts / inventaires :

- `StockMovement` inséré + `Stock.quantity` mis à jour **par `increment`** (jamais une valeur absolue),
  dans la transaction de l'appelant ;
- la ligne de projection est **verrouillée (`SELECT … FOR UPDATE`)** avant la vérification : sans ce
  verrou, deux ventes concurrentes de la dernière unité passeraient toutes les deux. C'est le seul
  SQL brut du projet, en *tagged template* Prisma donc paramétré ;
- le test est fait sur le **disponible** (`quantity − reservedQuantity`), conformément à
  `StockDto.availableQuantity` du contrat ;
- `Product.allowBackorder` est la seule dérogation.

### 3. Étendre le sync = écrire un handler, jamais toucher au moteur

`SyncMutationHandler` (`src/sync/sync-mutation.handler.ts`) : type d'opération, permissions exigées,
entité auditée, `validate(payload)`, `apply(payload, ctx)` dans la transaction du moteur.
Inscription dans `SYNC_MUTATION_HANDLERS` (`src/sync/sync.module.ts`). Convention ajoutée à
`CONVENTIONS.md` § Sync.

**Un seul handler existe aujourd'hui** : `MANUAL` = perte/casse au dépôt (permission `stock.loss`),
la seule opération dont la feature est assez avancée pour être synchronisable. Elle exerce tout le
contrat. Les autres types (`SALE`, `RECEPTION`, `TRANSFER`…) répondent `NON_TRAITEE` /
`NOT_IMPLEMENTED` et leur handler arrivera **avec leur feature**.

### 4. Migration additive

`20260909065518_sync_rejection_code` — `SyncMutation.rejectionCode TEXT NULL`.
Sans elle, un renvoi de mutation rejetée ne rendait que le motif en français, pas le code métier
stable : le client n'aurait pas pu réagir programmatiquement (voir `docs/context.md`, journal).

### Preuves réelles (sorties collées)

Tests unitaires du moteur :
```
$ npx jest src/sync --verbose
PASS src/sync/sync.service.spec.ts
  SyncService
    √ applique une mutation valide et trace l'audit dans la même transaction
    √ ne rejoue JAMAIS une mutation déjà traitée (idempotence)
    √ renvoie le rejet mémorisé, avec son code stable, sur un renvoi
    √ rejette une mutation dont l'utilisateur n'a pas la permission — comme en ligne
    √ rejette la mutation d'un membre qui a la permission mais PAS le rôle
    √ ne divulgue JAMAIS le résultat mémorisé d'un autre utilisateur
    √ rejette DÉFINITIVEMENT un identifiant d'entité déjà pris, sans geler la file
    √ rejette un payload invalide sans ouvrir de transaction
    √ rejette une règle métier violée en gardant le motif lisible
    √ garde en file une opération dont le handler n'existe pas encore
    √ rejoue le lot dans l'ordre du timestamp appareil, quel que soit l'ordre d'envoi
    √ n'écrit rien et arrête le lot sur une panne technique (ordre préservé)
Tests:       12 passed, 12 total
```

Tests d'intégration du sync, sur la vraie base PostgreSQL :
```
$ npx jest --config ./test/jest-e2e.json sync --runInBand --verbose
PASS test/sync.e2e-spec.ts
  Sync (e2e)
    √ refuse la synchronisation sans token
    √ applique une perte saisie hors-ligne : mouvement + projection
    √ ne réapplique JAMAIS une mutation renvoyée (idempotence)
    √ n'applique qu'une fois deux envois CONCURRENTS de la même mutation
    √ rejette une mutation qui rendrait le stock négatif, SANS effet de bord
    √ mémorise le rejet : le renvoi donne le même verdict, sans retraitement
    √ autorise le négatif sur un produit en backorder
    √ rejette la perte déclarée par un vendeur : la matrice vaut aussi hors-ligne
    √ rejette un payload non conforme au contrat
    √ garde en file une opération dont la feature n'est pas encore livrée
    √ applique le lot dans l'ordre du timestamp appareil, pas celui d'envoi
    √ refuse le vendeur À QUI la permission a été accordée : le rôle manque toujours
    √ rejette DÉFINITIVEMENT un id de mouvement déjà pris, sans geler la file
    √ ne renvoie pas à un autre compte le résultat mémorisé d'un collègue
  StockLedgerService (socle partagé)
    √ n'empêche JAMAIS une entrée, même si le disponible est déjà négatif
    √ refuse la sortie qui creuse un disponible déjà négatif
    √ refuse un mouvement de quantité nulle
Tests:       17 passed, 17 total
```

Suites complètes, après ajout (aucune régression) :
```
$ npm test
PASS src/common/roles.guard.spec.ts
PASS src/common/jwt-access.guard.spec.ts
PASS src/auth/auth.service.spec.ts
PASS src/sync/sync.service.spec.ts
Test Suites: 4 passed, 4 total
Tests:       33 passed, 33 total

$ npm run test:e2e
PASS test/sync.e2e-spec.ts
PASS test/auth.e2e-spec.ts
Test Suites: 2 passed, 2 total
Tests:       34 passed, 34 total
```

Build + serveur réellement démarré, contrat servi :
```
$ npm run build && node dist/main.js
$ curl -s http://localhost:3000/api/health
{"status":"ok","timestamp":"2026-09-09T07:16:03.149Z"}

$ curl -X POST http://localhost:3000/api/sync -d '{"mutations":[]}'   # sans token
{"statusCode":401,"message":"Access token manquant","error":"UNAUTHORIZED","code":"ACCESS_TOKEN_MISSING"}

# OpenAPI : POST /api/sync présent, tag « Synchronisation »,
# corps SyncBatchDto → réponse SyncBatchResultDto  (61 opérations, 61 schémas, 20 tags)
```

Aller-retour réel à travers le serveur — idempotence d'un **rejet** :
```
$ curl -X POST /api/sync … (mutation MANUAL sur un produit inexistant)
{"results":[{"clientMutationId":"b72d279c-…","status":"REJETEE","code":"NOT_FOUND",
             "reason":"Produit introuvable : a3796d2b-…","alreadyProcessed":false}]}

$ (même mutation renvoyée)
{"results":[{"clientMutationId":"b72d279c-…","status":"REJETEE","code":"NOT_FOUND",
             "reason":"Produit introuvable : a3796d2b-…","alreadyProcessed":true}]}
```

### Audit sécurité — 3 points importants trouvés, tous corrigés

Aucun problème critique. Le noyau (atomicité, anti-stock-négatif sous concurrence, idempotence sous
concurrence, SQL paramétré, audit transactionnel, whitelist stricte) a été vérifié conforme.
Corrigé dans la foulée, avec un test dédié pour chaque :

1. **Un id d'entité déjà pris gelait la file de l'appareil.** Le client fournit les UUID (contrat §1) ;
   un `payload.id` déjà utilisé faisait échouer la transaction sur une violation d'unicité qui était
   interprétée comme « course d'idempotence », donc renvoyée en `SYNC_RETRY_LATER` — le client
   renvoyait alors la mutation **indéfiniment**, bloquant tout ce qui la suivait. Désormais la
   violation est discriminée sur la contrainte : seule celle qui porte sur `clientMutationId` est une
   course, toute autre est un `CONFLICT` **définitif**.
   > Piège Prisma 7 : avec le driver adapter PostgreSQL, la contrainte fautive n'est PAS dans
   > `meta.target` (absent) mais dans `meta.driverAdapterError.cause.constraint.index`.
2. **Mémoire d'idempotence non cloisonnée par utilisateur.** Rejouer le `clientMutationId` d'un
   collègue renvoyait SON résultat (id de mouvement, motif de rejet contenant produit, emplacement et
   quantité disponible), et pouvait faire croire à l'appelant que son opération était appliquée alors
   que rien ne l'avait été. Le résultat mémorisé n'est plus rendu qu'à son propriétaire ; sinon
   `CONFLICT` générique, sans rien divulguer.
3. **La matrice de rôles n'était pas appliquée par mutation.** Le handler n'exigeait qu'une
   permission. Un vendeur à qui l'admin accorde `stock.loss` « à la carte » était donc refusé sur
   `POST /stock/losses` mais **accepté** via `/sync`. Le handler déclare maintenant `requiredRoles`,
   vérifié avant les permissions, exactement comme `RolesGuard` en ligne.

Corrections mineures appliquées au passage : refus d'accès tracés en `warn` (supervision) ·
`AuditLog.ipAddress` renseigné · `deviceTimestamp` refusé au-delà de +24 h (horloge déréglée ou
tentative de forcer l'ordre du lot) · création de la ligne de projection en
`INSERT … ON CONFLICT DO NOTHING` — un upsert concurrent aurait levé une erreur d'unicité qui, en
PostgreSQL, avorte toute la transaction · lecture verrouillée rendue défensive.

### État exact du code
- `backend/` compile, **67 tests passent** (33 unitaires + 34 e2e), serveur démarre, `/docs` répond.
- Auth **complète**, socle de sync **complet et prouvé**.
- Features métier **non implémentées** (contrat figé, 501) — sauf le mouvement de stock, dont le
  noyau existe désormais (`StockLedgerService`) sans être encore exposé en ligne.
- `app/` (Flutter) n'existe toujours pas.
- Bloqué sur : rien.

### ⚠️ Prérequis d'environnement découvert cette session
**Node ≥ 22.12 (ou 20.19+, ou 24+) est OBLIGATOIRE** : Prisma 7 refuse de s'installer sur Node 23.x
(`Prisma only supports Node.js versions 20.19+, 22.12+, 24.0+`) et `npm install` échoue en preinstall.
Testé et validé sur **Node 22.23.2**. Sur macOS : `brew install node@22` puis
`export PATH="/opt/homebrew/opt/node@22/bin:$PATH"`.

Rappel de mise en route d'une machine vierge :
```bash
cd infra && docker compose -f docker-compose.dev.yml up -d
cd ../backend && cp .env.example .env      # puis générer JWT_ACCESS_SECRET
npm install && npx prisma generate && npx prisma migrate deploy && npm run seed
```
> `npx prisma migrate dev` ne régénère pas toujours le client dans `src/generated/prisma` :
> après toute modification du schéma, enchaîner explicitement `npx prisma generate`.

### Prochaine étape précise — étape 4 de la Phase 0 : structure Flutter de base (`app/`)
C'est la **dernière** brique avant les features P0. À livrer par le Dev B (frontend) :
1. `flutter create app` à la racine, structure de `CLAUDE.md` (`lib/core`, `lib/data`,
   `lib/features`, `lib/ui/desktop`, `lib/ui/mobile`) et de `CONVENTIONS.md`.
2. **Client Dio unique** : base URL configurable, intercepteur JWT + refresh automatique sur 401
   (rotation du refresh — l'ancien token devient invalide, voir §Auth), stockage des tokens en
   `flutter_secure_storage` **uniquement**.
3. **go_router** : shell desktop / shell mobile, redirection vers login si pas de session, et vers
   « changement de mot de passe obligatoire » si `mustChangePassword`.
4. **Base Drift + file de mutations locale** miroir du contrat : `clientMutationId` (UUID v7 généré
   à la saisie), `deviceId`, `operationType`, `payload`, `deviceTimestamp`, statut local
   (`en_attente` / `confirmée` / `rejetée` + code + motif).
5. **Moteur d'envoi** : lots ≤ 200 triés par `deviceTimestamp`, POST `/api/sync`, puis application des
   résultats — `CONFIRMEE` ⇒ retirer de la file · `REJETEE` ⇒ marquer échouée avec le `code` et le
   motif, action utilisateur requise · `NON_TRAITEE` ⇒ **laisser en file**, réessayer plus tard.
6. Thème (sombre, accent cyan/bleu électrique — `docs/spec-fonctionnelle.md`) + les 6 états d'écran
   `Loading / Empty / Error / Success / Offline / SyncPending`.
7. Preuve attendue : `flutter test` + `flutter build` réels, et une capture de l'écran de login.

> Un endpoint de **delta sync descendant** (téléchargement du sous-ensemble par rôle, curseur serveur)
> n'existe pas encore : il n'est pas dans le socle exigé par la Phase 0 et sera fait avec les features
> qui ont des données à descendre. À prévoir avant la mise en service réelle.
>
> Rappel : **ne commencer aucune feature métier P0** tant que l'étape 4 n'est pas terminée.

## Sessions précédentes (à conserver — savoir durable)

### Étapes 1 et 2 — schéma, OpenAPI, auth, seed (2026-09-09, Dev A)
- **Schéma** : 35 tables migrées (`20260909024741_phase0_schema_initial`).
- **Contrat OpenAPI** : servi sur `/docs` (préfixe `api` pour les routes), squelette figé pour les
  features non développées — chaque route répond **501 `NOT_IMPLEMENTED`**, jamais une 404 trompeuse
  (`backend/src/common/api-contract.module.ts`).
- **Auth** : création de compte par l'admin seul ; login email OU téléphone, argon2id ; access JWT
  15 min ; refresh **opaque** stocké en SHA-256, 90 j glissants, **rotation à chaque appel**,
  révocable — rejouer un token révoqué ferme **toutes** les sessions ; `mustChangePassword`
  verrouille l'API sauf `change-password` / `logout` ; guards globaux `JwtAccessGuard` puis
  `RolesGuard`.
- **Seed** (`npm run seed`, idempotent) : 38 permissions, 3 rôles, 3 emplacements, 2 tarifs,
  2 taux de TVA, 1 admin.
- **Audit sécurité passé**, avec corrections appliquées : rate limiting sur `/auth/login` (10/15 min)
  et `/auth/refresh` (30), rotation du refresh rendue atomique, anti-énumération temporelle,
  réutilisation du mot de passe courant refusée, dernier admin protégé, `extraPermissions` validé,
  Swagger fermé en production, codes `ACCESS_TOKEN_MISSING` / `ACCESS_TOKEN_INVALID` distincts.

### Pièges d'infrastructure déjà rencontrés — ne pas les re-découvrir
- **`DATABASE_URL` est câblé à DEUX endroits** : `prisma7.config.ts` = **CLI**, `PrismaService` =
  **runtime**. En Prisma 7 le `datasource` du schéma n'a pas de ligne `url` et le client exige un
  *driver adapter* (`new PrismaPg({ connectionString })`), sinon : « *PrismaClient was instantiated
  without any options. A driver adapter is required* ». Les deux lisent `backend/.env`.
- **Client Prisma généré dans `src/generated/`** (et non `backend/generated/`) : hors de `src`, il
  décalait la sortie du build en `dist/src/main.js` et cassait `npm run start:prod`.
- **`incremental` retiré de `tsconfig.json`** : combiné au `deleteOutDir` de Nest, tsc croyait le
  build à jour alors que `dist/` venait d'être supprimé → build silencieusement vide.
- ⚠️ **Reste à supprimer à la main** : l'ancien dossier `backend/generated/` (mort, gitignoré).

### Permissions — règles à ne pas oublier
- `docs/permissions.md` est **VALIDÉE (2026-09-09)**. Traduction technique unique :
  `backend/src/common/permissions.ts`, lu par le seed **et** par les guards.
- Le **vendeur n'a aucun accès aux fournisseurs** (ligne « Gérer fournisseurs » scindée en
  lecture/gestion) — verrouillé par un test e2e.
- ⚠️ Le seed fait autorité sur les permissions des rôles (il utilise `set`). Après toute modification
  de `permissions.ts`, **relancer `npm run seed`** — sinon la base garde l'ancien jeu et les tokens
  émis restent périmés.
- **Garde-fou structurel** : une route authentifiée **sans `@Roles` explicite est refusée**
  (`FORBIDDEN_ROLE`). Oublier le décorateur ferme la route au lieu de l'ouvrir.

## Dette assumée (à traiter à sa feature)
- **Audit des actions de gestion de comptes** (création, changement de rôles/permissions, reset de
  mot de passe, révocation) : n'écrit toujours pas dans `AuditLog`. Feature P0 n°11 « Historique /
  audit », à faire dans la même transaction que la mutation, acteur pris via `@CurrentUser()`.
  _(Le sync, lui, écrit déjà son audit.)_
- **Réservation de stock** (`Stock.reservedQuantity`) : le disponible la déduit déjà, mais **rien ne
  la remplit** — quand on réserve et quand la réservation expire reste à décider (feature Ventes).
- **Débit et taille de corps sur `/sync`** (relevé à l'audit, non corrigé) : la route hérite du
  throttle global (120 req/min **par IP** — or tous les postes du magasin sortent derrière la même IP)
  et de la limite de corps par défaut d'Express (**100 ko**). Un lot de 200 ventes dépassera 100 ko et
  serait refusé en 413. Les deux valeurs doivent être calibrées **quand le premier handler lourd
  arrivera** (vente), pas au jugé maintenant.
- **Payload d'un rejet de validation stocké tel quel** (`SyncMutation.payload`) : un compte
  authentifié peut faire grossir la table avec du JSON arbitraire, borné seulement par la limite de
  corps. À plafonner/tronquer si la volumétrie devient un sujet.
- **Formatage** : le dépôt n'est pas `prettier`-clean (37 fichiers, tous antérieurs à cette session
  compris ; seule la largeur de ligne diffère). Le passage de `npm run format` est à faire en une
  fois, dans un commit dédié, quand les deux devs sont d'accord — pas au milieu d'une feature.

## Avancement par feature

| Feature | Statut | Backend | Frontend | Tests | Sécurité |
|---|---|---|---|---|---|
| Phase 0 — Fondation (schéma + OpenAPI + auth + socle sync) | 🟡 En cours | 🟢 Schéma · 🟢 OpenAPI · 🟢 Auth · 🟢 Socle sync | 🔴 Étape 4 à faire | 🟢 33 unit + 34 e2e | 🟢 Audits passés |
| Auth + rôles/permissions | 🟢 Backend terminé | 🟢 Login/refresh/logout/guards/seed | 🔴 À faire | 🟢 38 tests | 🟢 Audit passé |
| Socle offline/sync (moteur + contrat) | 🟢 Backend terminé | 🟢 `POST /api/sync` idempotent + rejets | 🔴 À faire (étape 4) | 🟢 29 tests | 🟢 Audit passé, 3 correctifs |
| Produits + catégories + emplacements | 🔴 Non commencé | 🟡 Contrat figé (501) | — | — | — |
| Stock + mouvements | 🟡 Noyau prêt | 🟡 `StockLedgerService` prêt · routes 501 | — | 🟢 couvert via le sync | — |
| Ventes (tarifs, TVA/facture, caisse) + dettes clients + paiements | 🔴 Non commencé | 🟡 Contrat figé (501) | — | — | — |
| Fournisseurs + clients + dettes fournisseurs | 🔴 Non commencé | 🟡 Contrat figé (501) | — | — | — |
| Achats | 🔴 Non commencé | 🟡 Contrat figé (501) | — | — | — |
| Réceptions (dont partielles) | 🔴 Non commencé | 🟡 Contrat figé (501) | — | — | — |
| Transferts magasin↔dépôt | 🔴 Non commencé | 🟡 Contrat figé (501) | — | — | — |
| Inventaire + tournant | 🔴 Non commencé | 🟡 Contrat figé (501) | — | — | — |
| Planning hebdomadaire | 🔴 Non commencé | 🟡 Contrat figé (501) | — | — | — |
| Historique/audit | 🔴 Non commencé | 🟡 Contrat figé (501) | — | — | — |
| Génération PDF/Excel, devis, étiquettes code-barres (P1) | 🔴 Non commencé | — | — | — | — |
| Handlers de sync par opération P0 (vente, réception, transfert, inventaire) | 🔴 Non commencé | 🟡 Moteur prêt, 1 handler livré | — | — | — |

Légende : 🔴 non commencé · 🟡 en cours · 🟢 terminé et prouvé

## Décisions en attente
- ~~Matrice de permissions CRUD détaillée par entité~~ → **VALIDÉE le 2026-09-09** (`docs/permissions.md`).
- Confirmer les canaux de notification temps réel (WebSocket) au moment de la feature Notifications (P1).
- **Quand réserve-t-on du stock** (`reservedQuantity`) et quand la réservation expire-t-elle ?
  À trancher au démarrage de la feature Ventes.
