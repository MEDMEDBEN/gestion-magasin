# État d'avancement

> Les deux devs travaillent à des heures différentes, jamais en simultané — ce fichier EST le relais entre vous deux.
> Règle stricte : `git pull` + lire ce fichier en entier AVANT de coder. Le mettre à jour + `git push` avant de fermer la session.
> Au retour, dire simplement "lis tasks.md et continue" plutôt que de reprendre l'historique complet.

## Phase actuelle
**`Phase 0 — Fondation` : TERMINÉE.** Les 6 cases de `docs/plan.md` sont cochées.
Prochaine phase : **features P0, dans l'ordre**, en commençant par la n°1.

> ⚠️ Une réserve à lever avant de considérer la Phase 0 close côté machine :
> `flutter build windows` ne passe pas encore ici — prérequis d'environnement, pas un défaut de code.
> Détail et solution dans « Réserve ouverte » plus bas.

## Dernier relais
- Date : 2026-09-09
- Qui a travaillé : **MEDMEDBEN** (backend + frontend cette session)
- Ce qui a été fait : **étape 4 de la Phase 0 — structure Flutter de base (`app/`)**.
  Les étapes 1 à 3 n'ont pas été retouchées, sauf une ligne sur `/auth/me` (voir plus bas).

> 📌 **Signature du relais** : nous nous signions tous les deux « Dev A », ce qui rendait
> `tasks.md` ambigu sur qui avait fait quoi. À partir de maintenant, **signer par nom**
> (MEDMEDBEN / Ratybox) plutôt que par rôle.

### 1. Ce qui a été livré dans `app/`

Projet Flutter 3.44.8 (`flutter create`, plateformes **windows + android** — le web est
hors périmètre et a été retiré), structure conforme à `CLAUDE.md` et `CONVENTIONS.md` :

```
app/lib/
├── core/        config · error (codes miroir du backend) · money · quantity · providers · router
├── data/        api (dio_client, auth_api, sync_api) · local (token_store, drift, mutation_queue)
│                models (freezed) · sync (sync_engine)
├── features/    auth/ (application + presentation)
└── ui/          theme · widgets · desktop/ · mobile/
```

- **Client Dio UNIQUE** avec intercepteur JWT + refresh automatique sur 401.
- **Tokens en `flutter_secure_storage` uniquement** — jamais dans Drift, jamais en clair.
- **go_router** : redirections login / changement de mot de passe obligatoire.
- **Drift + file de mutations** : miroir exact du corps de `POST /api/sync`.
- **Moteur de sync** : lots ≤ 200 triés par `deviceTimestamp`, application des 3 verdicts.
- **Thème sombre** bleu nuit + accent cyan, et les **6 états d'écran** obligatoires.

### 2. Points de conception à connaître avant de toucher à `app/`

- **Le refresh est mutualisé (`_refreshInFlight`)** et ne doit JAMAIS cesser de l'être.
  Le serveur fait une **rotation** du refresh token et traite le rejeu d'un token révoqué
  comme un **vol** : il ferme *toutes* les sessions. Deux refresh concurrents
  déconnecteraient donc l'utilisateur de tous ses appareils.
- **Une panne serveur n'efface JAMAIS la session.** Sur 5xx / 429 / 408, on conserve les
  tokens et on réessaiera : effacer couperait l'accès à des ventes hors-ligne encore en file.
  Seuls un 401 définitif et une absence totale de réponse (`statusCode == 0`, cas ambigu)
  ferment la session.
- **`clientMutationId` est généré à la SAISIE et n'est jamais régénéré.** C'est toute la
  garantie d'idempotence. Corriger une mutation rejetée = créer une **nouvelle** mutation.
- **Les compteurs de sync sont des `StreamProvider`** (requêtes Drift observées), pas des
  `Future` : l'indicateur doit bouger tout seul après une saisie ou un cycle de sync.
- **Aucun `double`** ne porte un montant ni une quantité : `Money = int` (centimes),
  `Quantity = Decimal`, transport JSON en chaîne.
- **Le séparateur de milliers est construit par `String.fromCharCode(0x202F)`**, jamais écrit
  en littéral : une espace invisible dans le source avait déjà provoqué des tests
  faux-négatifs impossibles à lire.

### 3. Une modification du backend, assumée

`GET /api/auth/me` reçoit `@AllowPasswordChange()` : l'app doit pouvoir afficher **qui**
elle verrouille sur l'écran de changement de mot de passe. La route ne rend que le profil du
demandeur, aucune action métier n'est déverrouillée. Le test e2e correspondant vérifie
désormais qu'une vraie **route métier** (`/api/products`) est bien bloquée en 403, et que
`/auth/me` répond 200 — le test est plus fort qu'avant.

### Preuves réelles (sorties collées)

Tests Flutter — 73, dont 10 sur l'intercepteur de refresh :
```
$ flutter test
00:04 +73: All tests passed!

Répartition :
  11 tests — test/money_test.dart
  10 tests — test/quantity_test.dart
  14 tests — test/mutation_queue_test.dart
   9 tests — test/sync_engine_test.dart
   9 tests — test/router_redirect_test.dart
  10 tests — test/dio_client_test.dart
  10 tests — test/widget_test.dart
```

Analyse statique :
```
$ flutter analyze
4 issues found.   (0 error, 0 warning — 4 infos `prefer_initializing_formals`
                   NON corrigeables : Dart interdit un paramètre nommé privé)
```

Backend — aucune régression après la modification de `/auth/me` :
```
$ npm run build   → OK
$ npm test        → Test Suites: 4 passed · Tests: 33 passed
$ npm run test:e2e → Test Suites: 2 passed · Tests: 34 passed
```

### 🐛 Bug corrigé au passage : `npm run test:e2e` était CASSÉ

La commande documentée dans `CLAUDE.md` **échouait sur les 34 tests**
(`UnsupportedMediaTypeError: unsupported charset "UTF-8"`) : les deux suites e2e tournaient
en parallèle sur la même base de dev. Elles passaient uniquement si on ajoutait `--runInBand`
à la main — ce que faisait la session précédente, sans le committer.
**Corrigé dans `backend/package.json`** : le script porte désormais `--runInBand`.
→ Leçon : toujours valider la commande **telle qu'elle est documentée**, pas une variante locale.

### Audit `security-reviewer` — 4 points bloquants trouvés, tous corrigés

Aucune faille exploitable de l'extérieur (pas de secret, pas de token mal stocké, pas de
contournement de permission côté client, pas d'injection). Mais 4 défauts qui **détruisaient
une session sur un simple hoquet serveur** — et donc l'accès aux ventes hors-ligne non
synchronisées. Tous corrigés, chacun avec son test :

1. **Refresh** : un 500 / 429 / timeout effaçait les tokens → n'efface plus que sur verdict
   définitif (`dio_client.dart`).
2. **Démarrage** : `_restoreSession()` effaçait la session sur n'importe quelle erreur → ne
   le fait plus que sur 401 / `requiresRelogin` (`auth_controller.dart`).
3. **Hors-ligne au lancement** : l'app restait bloquée sur un spinner **sans issue** → écran
   « Serveur injoignable » avec bouton *Réessayer* (`adaptive_shell.dart`).
4. **Rejets invisibles** : une mutation `REJETEE` n'était affichée nulle part, violation
   directe de `docs/context.md` §6 (une vente refusée disparaissait silencieusement) →
   `rejectedMutationsProvider` + affichage dans les deux shells.

Mineurs également corrigés : double rotation du refresh sur 401 décalés · `AuthSession.toString()`
n'imprime plus les tokens en clair · une ligne de payload corrompue ne bloque plus toute la
file (« poison pill ») · ajout du fichier de tests `dio_client_test.dart` qui manquait.

**Deuxième passe d'audit — feu vert obtenu**, après 4 correctifs supplémentaires :
- le `catch` du poison pill n'attrapait que `FormatException` : un JSON **valide mais pas un
  objet** (`[1,2]`) levait un `TypeError` et rebloquait tout le lot. `catch` élargi ;
- un 403 sur `/auth/me` affichait « Serveur injoignable » avec un bouton *Réessayer* qui
  bouclait → message clair, sans effacer les tokens ;
- ajout d'une **fenêtre de silence de 5 s** après un échec passager du refresh : sans elle,
  dix requêtes en 401 déclenchaient dix tentatives et brûlaient le quota throttlé ;
- deux tests ajoutés, dont celui qui **fige la décision du `statusCode == 0`** — c'est
  précisément celle qu'un futur contributeur sera tenté de transformer en retry, ce qui
  rouvrirait la détection de vol côté serveur.

### ⚠️ Réserve ouverte — `flutter build windows` ne passe pas ENCORE sur cette machine

Ce n'est **pas** un défaut du code (analyse propre, 73 tests verts), mais deux prérequis
d'environnement :

1. **Mode développeur Windows** — *réglé cette session* (symlinks de plugins Flutter,
   `HKLM\...\AppModelUnlock\AllowDevelopmentWithoutDevLicense = 1`).
2. **Composant ATL de Visual Studio — MANQUANT.** `flutter_secure_storage_windows` exige
   `atlstr.h`, absent des Build Tools 2019 installés :
   ```
   fatal error C1083: Impossible d'ouvrir le fichier include : 'atlstr.h'
   ```
   Correctif : ajouter `Microsoft.VisualStudio.Component.VC.ATL` via Visual Studio Installer.
   **Non tenté volontairement** : il ne reste que **~1,0 Go libre sur `C:`**, l'installation
   risquait de saturer le disque système. **Libérer de l'espace d'abord.**

Le build **Android** n'a pas été tenté non plus : `flutter doctor` signale la toolchain
Android absente (`[X] Android toolchain`).

→ **À faire par le prochain dev** : libérer de l'espace disque, installer le composant ATL,
puis lancer `flutter build windows --release` et coller la sortie ici. Tant que ce n'est pas
fait, la Phase 0 est fonctionnellement terminée mais son critère « preuve de build » ne l'est
qu'à moitié.

### État exact du code
- `backend/` : compile, **67 tests** (33 unitaires + 34 e2e), serveur démarre, `/docs` répond.
- `app/` : **73 tests**, analyse propre. Session, sync et thème en place ;
  **aucun écran métier** — ils arrivent avec les features P0.
- Bloqué sur : rien (la réserve build est un prérequis machine, pas un blocage de code).

### Mise en route d'une machine vierge
```bash
# Infra
cd infra && docker compose -f docker-compose.dev.yml up -d

# Backend  (Node 22.12+ OBLIGATOIRE — Prisma 7 refuse Node 23.x)
cd ../backend && cp .env.example .env      # puis générer JWT_ACCESS_SECRET
npm install && npx prisma generate && npx prisma migrate deploy && npm run seed
npm run start:dev

# App  (Flutter 3.44+ ; ici hors PATH, dans C:\flutter\bin)
cd ../app && flutter pub get
dart run build_runner build     # freezed + json_serializable + drift
flutter test
```
> Le code généré (`*.g.dart`, `*.freezed.dart`) est **gitignoré**, comme le client Prisma :
> lancer `build_runner` après tout `git pull` qui touche un modèle ou la base Drift.

### ➡️ Prochaine étape précise : **feature P0 n°1 — Authentification + utilisateurs + rôles**

La Phase 0 est finie : on entre dans les **tranches verticales**, une feature complète à la
fois (`CLAUDE.md` § Méthodologie). La n°1 est en grande partie faite **côté backend** ; il
reste à la terminer de bout en bout.

Reste à faire pour la clore :
1. **UI desktop** : écran de gestion des utilisateurs (liste paginée, création, modification
   des rôles/permissions, désactivation, réinitialisation de mot de passe, révocation de
   sessions). Les endpoints existent déjà : `POST|GET /api/users`, `PATCH /api/users/:id`,
   `POST /api/users/:id/reset-password|revoke-sessions`.
2. **UI mobile** : consultation de son propre profil ; la gestion des comptes reste desktop
   (`spec-fonctionnelle.md` §29 : la configuration lourde est desktop).
3. **`AuditLog` sur les actions de comptes** — dette explicitement reportée depuis l'étape 2 :
   création, changement de rôles/permissions, reset de mot de passe, révocation doivent
   écrire dans `AuditLog`, **dans la même transaction** que la mutation, acteur pris via
   `@CurrentUser()`. C'est le bon moment : c'est la feature qui les produit.
4. **Tests** : e2e backend pour l'audit, tests de widgets pour les écrans.
5. Revue `reviewer` + audit `security-reviewer`, puis cocher la checklist de `docs/plan.md`.

> Rappel : **ne pas démarrer la feature P0 n°2** (Produits) tant que la n°1 n'est pas
> terminée ET testée.

## Sessions précédentes (à conserver — savoir durable)

### Étape 3 — socle de sync (2026-09-09, Ratybox)
- `POST /api/sync` idempotent : `CONFIRMEE` / `REJETEE` mémorisés, `NON_TRAITEE` jamais.
- `StockLedgerService` (`src/stock/`) : règle 2 (mouvement source de vérité + projection dans
  la même transaction) + anti-stock-négatif, avec `SELECT … FOR UPDATE` contre les ventes
  concurrentes de la dernière unité. **Tout mouvement de stock doit passer par lui.**
- Étendre le sync = **écrire un handler**, jamais toucher au moteur (voir `CONVENTIONS.md` § Sync).
  Un seul handler existe : `MANUAL` (perte/casse). Les autres types répondent `NON_TRAITEE`.
- Migration additive `20260909065518_sync_rejection_code`.
- Audit passé, 3 correctifs : id d'entité déjà pris ne gèle plus la file · mémoire
  d'idempotence cloisonnée par utilisateur · rôle **ET** permission vérifiés par mutation.

### Étapes 1 et 2 — schéma, OpenAPI, auth, seed (2026-09-09, MEDMEDBEN)
- **Schéma** : 35 tables (`20260909024741_phase0_schema_initial`).
- **Contrat OpenAPI** sur `/docs` ; les routes non implémentées répondent **501
  `NOT_IMPLEMENTED`**, jamais une 404 trompeuse.
- **Auth** : comptes créés par l'admin seul ; login email OU téléphone (argon2id) ; access JWT
  15 min ; refresh **opaque** stocké en SHA-256, 90 j glissants, **rotation à chaque appel**,
  révocable ; `mustChangePassword` verrouille l'API ; guards globaux `JwtAccessGuard` puis
  `RolesGuard`.
- **Seed** idempotent : 38 permissions, 3 rôles, 3 emplacements, 2 tarifs, 2 TVA, 1 admin.

### Pièges d'infrastructure — ne pas les re-découvrir
- **Node ≥ 22.12 obligatoire** (Prisma 7 refuse Node 23.x). Validé sur 22.14 et 22.23.2.
- **`DATABASE_URL` est câblé à DEUX endroits** : `prisma7.config.ts` = **CLI**,
  `PrismaService` = **runtime** (Prisma 7 exige un *driver adapter* `PrismaPg`).
- **Client Prisma généré dans `src/generated/`** : ailleurs, il décale la sortie du build.
- **`incremental` retiré de `tsconfig.json`** : avec le `deleteOutDir` de Nest, tsc croyait le
  build à jour alors que `dist/` venait d'être supprimé → build silencieusement vide.
- **`npx prisma migrate dev` ne régénère pas toujours le client** : enchaîner `npx prisma generate`.
- **Flutter est hors PATH** sur cette machine : `export PATH="/c/flutter/bin:$PATH"`.
- ⚠️ **Reste à supprimer à la main** : `backend/generated/` (mort, gitignoré).

### Permissions — règles à ne pas oublier
- `docs/permissions.md` est **VALIDÉE (2026-09-09)**. Traduction technique unique :
  `backend/src/common/permissions.ts`, lu par le seed **et** par les guards.
- Le **vendeur n'a aucun accès aux fournisseurs** — verrouillé par un test e2e.
- ⚠️ Le seed fait autorité sur les permissions des rôles (il utilise `set`). Après toute
  modification de `permissions.ts`, **relancer `npm run seed`**.
- **Garde-fou structurel** : une route authentifiée **sans `@Roles` explicite est refusée**.

## Dette assumée (à traiter à sa feature)
- **`AuditLog` sur la gestion de comptes** → à faire dans la feature P0 n°1, ci-dessus.
- **UX de réconciliation des mutations rejetées** — `docs/context.md` §6 exige que
  l'utilisateur puisse **agir** sur un rejet (annuler / corriger). Aujourd'hui le rejet est
  bien COMPTÉ et affiché dans l'indicateur, mais aucun écran ne liste les mutations rejetées
  avec leur motif, et `MutationQueue.discard()` n'a encore aucun appelant. **Prérequis de la
  première feature qui crée des mutations (Ventes)** — sinon le §6 reste à moitié tenu.
- **Fenêtre de grâce sur le refresh token** (relevée à l'audit, non corrigée) : si la rotation
  aboutit côté serveur mais que la réponse se perd, le client se retrouve avec un refresh
  mort-né et doit se reconnecter. Correctif propre = accepter côté serveur un refresh révoqué
  depuis moins de ~30 s en renvoyant le successeur déjà émis, au lieu de déclencher la
  détection de vol. À faire quand on touchera à l'auth.
- **Réservation de stock** (`Stock.reservedQuantity`) : le disponible la déduit déjà, mais
  **rien ne la remplit**. À trancher au démarrage de la feature Ventes.
- **Débit et taille de corps sur `/sync`** : throttle global 120 req/min **par IP** (tous les
  postes du magasin sortent derrière la même IP) et limite de corps Express de **100 ko** —
  un lot de 200 ventes dépassera. À calibrer quand le premier handler lourd arrivera.
- **Base Drift locale non chiffrée** : conforme au besoin actuel (seuls les tokens exigent le
  stockage sécurisé), à reconsidérer si des appareils mobiles non maîtrisés entrent dans le périmètre.
- **Delta sync descendant** (téléchargement du sous-ensemble par rôle, curseur serveur) :
  n'existe pas encore. À faire avec les features qui ont des données à descendre, avant la
  mise en service réelle.
- **Formatage** : le dépôt n'est pas `prettier`-clean. À passer en une fois, dans un commit
  dédié, quand les deux devs sont d'accord — pas au milieu d'une feature.

## Avancement par feature

| Feature | Statut | Backend | Frontend | Tests | Sécurité |
|---|---|---|---|---|---|
| **Phase 0 — Fondation** | 🟢 **Terminée** | 🟢 Schéma · OpenAPI · Auth · Sync | 🟢 Structure, session, sync, thème | 🟢 67 backend + 73 app | 🟢 3 audits passés |
| Auth + rôles/permissions (P0 n°1) | 🟡 Backend fait, UI à faire | 🟢 Complet | 🔴 Écrans à faire | 🟢 38 tests | 🟢 Audit passé |
| Produits + catégories + emplacements | 🔴 Non commencé | 🟡 Contrat figé (501) | — | — | — |
| Stock + mouvements | 🟡 Noyau prêt | 🟡 `StockLedgerService` prêt · routes 501 | — | 🟢 couvert via le sync | — |
| Ventes (tarifs, TVA/facture, caisse) + dettes clients | 🔴 Non commencé | 🟡 Contrat figé (501) | — | — | — |
| Fournisseurs + clients + dettes fournisseurs | 🔴 Non commencé | 🟡 Contrat figé (501) | — | — | — |
| Achats | 🔴 Non commencé | 🟡 Contrat figé (501) | — | — | — |
| Réceptions (dont partielles) | 🔴 Non commencé | 🟡 Contrat figé (501) | — | — | — |
| Transferts magasin↔dépôt | 🔴 Non commencé | 🟡 Contrat figé (501) | — | — | — |
| Inventaire + tournant | 🔴 Non commencé | 🟡 Contrat figé (501) | — | — | — |
| Planning hebdomadaire | 🔴 Non commencé | 🟡 Contrat figé (501) | — | — | — |
| Historique/audit | 🔴 Non commencé | 🟡 Contrat figé (501) | — | — | — |
| Handlers de sync par opération P0 | 🔴 Non commencé | 🟡 Moteur prêt, 1 handler livré | — | — | — |
| Génération PDF/Excel, devis, étiquettes (P1) | 🔴 Non commencé | — | — | — | — |

Légende : 🔴 non commencé · 🟡 en cours · 🟢 terminé et prouvé

## Décisions en attente
- ~~Matrice de permissions CRUD~~ → **VALIDÉE le 2026-09-09** (`docs/permissions.md`).
- Confirmer les canaux de notification temps réel (WebSocket) au moment de la feature Notifications (P1).
- **Quand réserve-t-on du stock** (`reservedQuantity`) et quand la réservation expire-t-elle ?
  À trancher au démarrage de la feature Ventes.
