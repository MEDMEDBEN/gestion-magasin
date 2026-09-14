# État d'avancement

> Les deux devs travaillent à des heures différentes, jamais en simultané — ce fichier EST le relais.
> Règle stricte : `git pull` + lire ce fichier en entier AVANT de coder. Le mettre à jour + `git push` avant de fermer.
> **Signer par NOM** (MEDMEDBEN / Ratybox), plus par rôle : on se signait tous les deux « Dev A ».

## Phase actuelle
`Phase 0` **TERMINÉE**. **FEATURE P0 #1 — Auth + utilisateurs : CLOSE le 2026-09-14** (écrans validés par
MEDMEDBEN ; seul le build Windows reste bloqué par un prérequis MACHINE, voir point 6).
En cours : **FEATURE P0 #2 — Produits + catégories + emplacements + codes-barres**.

## Dernier relais — 2026-09-13 · **MEDMEDBEN** reprend (point 1 soldé, suite en cours)

## Relais précédent — 2026-09-11 · **Ratybox** (session Claude Opus 5) · arrêtée à la demande

### ✅ FAIT ET PROUVÉ (tout est committé et poussé sur `develop`)
- **Outillage aligné** : Flutter **3.44.8** / Dart 3.12.2 (révision `058e0af2c2`, celle de
  MEDMEDBEN). Node 22 : `export PATH="/opt/homebrew/opt/node@22/bin:$PATH"` sur le Mac.
- **1er tour d'audits** : `security-reviewer` **NON CONFORME** (1 critique, 4 importants,
  11 mineurs) et `reviewer` **PAS OK** (3 bloquants, 17 à corriger, 17 suggestions) →
  **tout corrigé, un test par correctif** :
  - backend `d7c6c95` : compte désactivé refusé partout (C1), `trust proxy` (I1), accès relu en
    base sur `/users` (`FreshAccessGuard`, I4), dernier admin sous verrou (M1), identifiants
    normalisés et bornés (M2), permissions ADMIN non attribuables à la carte (M3),
    change-password atomique et audité (M4), quota change-password (M5), logout public (M6),
    config validée au démarrage (M8), filtre P2002→409 / 429→`RATE_LIMITED`, dédoublonnage.
  - app `ae8c16e` : file de mutations liée à son auteur (Drift v2, I2), « tout déconnecter » qui
    ne ment plus (I3), HTTPS imposé en release (M7), Android `allowBackup=false` + INTERNET (M9),
    rôles cumulés préservés (M10/B2), permissions à la carte dans le formulaire (B3), structure
    CONVENTIONS (C11), Danger/un seul primaire/focus/zoom texte/panneau latéral (C12-C16),
    thème par utilisateur, points de rupture 768/1180 avec rail, pagination « Afficher plus ».
- **Vérification visuelle** `360a488` : 11 écrans rendus avec les vraies polices (desktop,
  tablette, mobile, sombre/clair) → 2 défauts trouvés et corrigés (boutons pas en Archivo —
  Segoe UI sous Windows ; bande d'ombre du panneau). Outil :
  `cd app && flutter test test/tools/screen_captures_test.dart --dart-define=CAPTURE_OUT=<dossier>`.
  Backend réel démarré et testé au `curl` (health, 401/400 codés, logout public, refus de
  démarrer avec la clé JWT d'exemple).
- **2e tour (contre-audits)** — `security-reviewer` : **NON CONFORME** (1 important N1 + 9 mineurs) ;
  `reviewer` : **PAS OK** (1 bloquant N1-revue + 3 à corriger). Déjà corrigé (commit `c3333c7`,
  **sans tests dédiés encore**) : N1-sécu (token lié à sa session `sid` + `FreshAccessGuard`
  exige session vivante et refuse `mustChangePassword` en base — couvre aussi N2-revue), N2
  (UUID canonique, `CanonicalUuidPipe`), N3 (logout allDevices exige une session valide), N4
  (change-password en compare-and-swap), N5 (`$executeRaw` paramétré), N10 (quota de connexion
  par IP+identifiant, `TRUST_PROXY_HOPS` ≤ 2).
- Docs mises à jour : `CONVENTIONS.md` (structure Flutter clarifiée, règles UI/audit/sécurité —
  **à valider par MEDMEDBEN**), `docs/permissions.md`, `docs/context.md` (journal 2026-09-11),
  `docs/DEPLOYMENT.md`, `docs/plan.md` (checklist P0 #1).

### Preuves réelles (dernière exécution, 2026-09-11)
```
backend $ npx tsc --noEmit -p tsconfig.json   → aucune erreur
backend $ npm test                            → Test Suites: 8 passed · Tests: 55 passed
backend $ npm run test:e2e                    → Test Suites: 4 passed · Tests: 76 passed
app     $ flutter analyze                     → No issues found!
app     $ flutter test                        → +142 ~11 (11 ignorés = outil de captures)
app     $ flutter build windows --release     → "build windows" only supported on Windows hosts
```

### ⚠️ Pièges pour MEDMEDBEN après `git pull`
- Le backend **refuse de démarrer** si `JWT_ACCESS_SECRET` vaut la valeur d'exemple ou fait moins
  de 32 octets → régénérer : `openssl rand -base64 48` dans `backend/.env`.
- `TRUST_PROXY_HOPS` : 0 en dev (défaut), 1 en prod ; valeur > 2 refusée au démarrage.
- Les anciens access tokens (sans `sid`) sont refusés sur `/users` (401) : l'app se rafraîchit
  toute seule ; en test manuel, se reconnecter.
- Drift passe en **schéma v2** (colonne `authorUserId`) : migration automatique au lancement.
- `backend/generated/` (dossier mort, gitignoré) : toujours à supprimer à la main sur le poste Windows.

### ⛔ CE QU'IL RESTE À FAIRE POUR CLORE LA P0 #1 (reprise ICI, dans cet ordre)
1. ✅ **FAIT (2026-09-13, MEDMEDBEN)** — tests e2e dédiés aux correctifs `c3333c7` :
   `backend/test/session-hardening.e2e-spec.ts` (12 tests : N1 ×6, N2, N3 ×3, N4, N10) +
   `TRUST_PROXY_HOPS=3` refusé dans `src/common/env.spec.ts`. **Contre-épreuve** : le correctif
   N4 retiré, son test échoue → le test protège réellement. Preuve :
   `npm test` → 55 passed · `npm run test:e2e` → 5 suites, **88 passed** · `tsc` OK.
   > ⚠️ Piège machine Windows : le port 5432 peut être pris par un AUTRE projet
   > (`infinit-school-postgres-1`) → « Authentication failed for `dev` ». Ne pas couper ses
   > conteneurs : lancer le nôtre sur 5433 avec un override local non commité
   > (`ports: !override ["127.0.0.1:5433:5432"]`) et exporter
   > `DATABASE_URL=postgresql://dev:dev@localhost:5433/gestion_magasin_dev?schema=public`.
2. ✅ **FAIT (2026-09-13, MEDMEDBEN)** — restes mineurs du contre-audit sécurité, chacun testé
   ET contre-éprouvé (correctif retiré → test en échec) :
   - N6a : commentaire corrigé (`app_database.dart`) — `authorUserId` est une étiquette locale,
     pas une preuve d'auteur.
   - N7 : `logoutAllDevices` traite `revoked < 1` comme un échec, session locale conservée
     (`auth_controller_test.dart`).
   - N8 : `DioClient.awaitPendingRefresh()` attendu par `logout`/`logoutAllDevices` ; `_performRefresh`
     n'enregistre les tokens neufs que si le stockage contient encore le token utilisé, sinon
     ferme la session neuve côté serveur (`dio_client_test.dart`, 2 tests).
   - N9 : `android:dataExtractionRules` → `res/xml/data_extraction_rules.xml` (tout exclu en
     `cloud-backup` ET `device-transfer`), vérifié dans `android_manifest_test.dart`.
   - ⏳ **N6b reste un PRÉREQUIS, pas encore dû** : à faire AVANT de brancher réellement la sync
     dans l'app (`_inFlight` par auteur dans `sync_engine.dart` + `authorUserId` dans le lot, le
     serveur répond `NON_TRAITEE` s'il diffère du porteur du token). La sync n'est pas encore
     déclenchée par un écran.
   Preuve : `flutter analyze` → No issues found! · `flutter test` → **+146 ~11** All tests passed.
3. ✅ **TRANCHÉ ET FAIT (2026-09-13, MEDMEDBEN)** — bloquant N1 de la contre-revue : **cumul par
   RÔLES, suppression des permissions « à la carte »** (option b). Voir `docs/permissions.md` et le
   journal de `docs/context.md`.
   - backend : `extraPermissions` retiré des DTO (désormais refusé en 400), `assertGrantable`,
     `ADMIN_ONLY_PERMISSIONS` et `PERMISSION_NOT_GRANTABLE` supprimés ; `resolvePermissions` ne lit
     plus que les rôles ; `adminOnly` retiré du catalogue.
   - app : section « Permissions supplémentaires », `grantableFor`, `PermissionCatalog` et badge
     « +N permissions » supprimés ; le formulaire cumule en cochant plusieurs rôles.
   - tests : e2e « le champ n'existe plus → 400 », « une permission directe résiduelle en base
     n'accorde plus RIEN » (dont `supplier.read` au vendeur), « cumuler = union des rôles, tracé » ;
     widget « cocher 2 rôles envoie les 2 rôles ».
   Preuve : backend 55 unitaires · **88 e2e** · tsc OK ; app analyze propre · **146** tests.
4. ✅ **FAIT (2026-09-13, MEDMEDBEN)** — contre-revue « à corriger » :
   - N3-revue : `app/test/auth_api_test.dart` réécrit avec le VRAI `DioClient` + `MemoryTokenStore` ;
     nouveau test : un 401 sur logout ne déclenche aucun refresh ni fin de session.
   - S3 : Swagger documente le 403 `SELF_MODIFICATION_FORBIDDEN` (PATCH) sur
     `users.controller.ts` (le 422 `PERMISSION_NOT_GRANTABLE` a disparu avec le point 3).
   - S9 : `sync_api.dart` passe par `guardApi()`.
   - S14 : `login_screen.dart` — `autocorrect:false`, `enableSuggestions:false` sur les 2 champs.
   - S16 : dialogue « déconnecter tous les appareils » — réserve des 15 min écrite en clair.
   - Suggestions non bloquantes s1-s12 : **non traitées** (listées plus bas, à reprendre en
     repassant sur ces fichiers).
   Preuve : app analyze propre · **146** tests · backend 55 unitaires · **88** e2e · tsc OK.
5. ✅ **FAIT (2026-09-14, MEDMEDBEN)** — audits finaux relancés, puis TOUT corrigé :
   - `security-reviewer` : **CONFORME** (7 points vérifiés) + 3 mineurs, corrigés, chacun testé ET
     contre-éprouvé (correctif retiré → test en échec) :
     - mineur 1 : course refresh / révocation — la session neuve pouvait survivre à une révocation
       concurrente. Verrou consultatif PAR COMPTE (`lockUserSessions`) pris par la rotation et par
       `revokeAllForUser` (e2e « révocation lancée PENDANT une rotation »).
     - mineur 3 : un vieux token révoqué permettait de déconnecter la victime indéfiniment.
       Migration ADDITIVE `refresh_token_revoked_reason` (`RefreshToken.revokedReason`) : seul un
       token remplacé par ROTATION et non expiré déclenche la cascade « vol » ; logout, reset,
       révocation, reconnexion ou expiration → simple 401 (2 e2e).
     - mineur 2 (app) : `DioClient.beginSessionClose()/endSessionClose()` — aucune rotation ne
       démarre pendant une déconnexion (`dio_client_test.dart`).
   - `reviewer` : **PAS OK, aucun bloquant**, 5 points, tous corrigés :
     1. catalogue de permissions devenu mort → route, service, DTO et tests supprimés ;
     2. import `IsIn` inutilisé, lignes vides, test « permission inconnue » redondant supprimé,
        libellés Swagger « rôles/permissions » → « rôles » ;
     3. docs contradictoires réalignées : `spec-fonctionnelle.md` §2, `CLAUDE.md` (rôles), `plan.md`,
        `permissions.md`, `tasks.md` — conformément à la décision de MEDMEDBEN (cumul par rôles) ;
     4. N7 : l'exception n'invente plus le code `REFRESH_TOKEN_INVALID` (message « Session expirée »
        contradictoire) — test sur `userMessage` et `requiresRelogin` ;
     5. preuve e2e sur une vraie route : permission directe résiduelle → `GET /api/suppliers` 403.
   - suggestion appliquée : `awaitPendingRefresh` ne propage plus l'échec d'une rotation.
   Preuve backend : tsc OK · lint propre sur les fichiers touchés · **55** unitaires · **89** e2e.
   Preuve app : `flutter analyze` → No issues found! · `flutter test` → **+147 ~11** All tests passed.
   > ⚠️ **DISQUE `C:` SATURÉ (2026-09-14)** : le poste Windows est tombé à **0 Mo libre** pendant la
   > session — les tests Flutter échouaient au chargement (« Espace insuffisant sur le disque »,
   > errno 112), sans rapport avec le code. Seuls les caches temporaires `%TEMP%lutter_tools.*`
   > (506 Mo, régénérables) ont été supprimés ; il reste ~430 Mo. **Libérer de l'espace est urgent**
   > (Docker/PostgreSQL, compilation, build Windows) — action MEDMEDBEN.
6. ⏳ **Poste Windows — prérequis machine, non contourné** (re-vérifié 2026-09-14 : `atlstr.h` ABSENT, 2,3 Go libres) : `flutter build windows --release` (prérequis : composant VS
   `Microsoft.VisualStudio.Component.VC.ATL` + espace sur `C:`) — le noter ici sans contournement.
7. ✅ **FAIT (2026-09-14)** — écrans **validés par MEDMEDBEN** (« ça me va » ; une version améliorée de
   l'UI sera fournie plus tard, à appliquer en apparence seulement). Captures régénérées le 2026-09-14
   sur le poste Windows (11 écrans, `flutter test test/tools/screen_captures_test.dart
   --dart-define=CAPTURE_OUT=<dossier>`), relues par l'agent : conformes AMPÈRE, rôles cumulés,
   plus de section permissions. Un espace résiduel du formulaire mobile a été corrigé (`df214e4`).
   Ancien texte :  (captures via l'outil ci-dessus) → cocher dans `docs/plan.md`.

Suggestions non bloquantes de la contre-revue (à traiter quand on repasse sur ces fichiers) :
course recherche/`loadMore` (`users_controller.dart`) ; rayons/marges desktop dans
`user_form.dart` et `profile_screen.dart` ; liste mobile en lignes `lineSoft` plutôt qu'en cartes ;
dialogue avant déconnexion à assumer comme exception I2 ; calcul des changements du formulaire à
déplacer dans `application/` avec tests unitaires ; toast d'édition dupliqué ;
`catch` limité à `ApiException` dans `profile_screen.dart` / `user_actions.dart` ; typer
`PERMISSION_DESCRIPTIONS` ; base de test e2e dédiée (le helper désactive les vrais admins de la
base de dev le temps d'un test) ; constantes pour les `operation` d'audit ; panneau latéral qui se
ferme au clic extérieur (perte de saisie).

### 🚧 P0 #2 EN COURS — 2026-09-14 · **MEDMEDBEN** — backend + app faits et prouvés, audits en cours
Fait (committé) :
- `backend/src/common/barcode/barcode.ts` : clé GS1, EAN-13 interne `20`+séquence+clé, contrôle de clé
  des GTIN saisis (8/12/13/14), codes alphanumériques acceptés (64 max). **5 tests unitaires verts.**
- Migration ADDITIVE appliquée (`migrate deploy`) :
  `prisma/migrations/20260914120000_product_internal_barcode_seq` (CREATE SEQUENCE).
- Produits (`products.service.ts`) : liste `{data, meta}` (q nom/SKU/marque/code, `categoryId` avec
  sous-catégories, `includeInactive`, tri whitelisté), détail, recherche par code-barres, création
  (id client, code généré si absent, SKU unique sans la casse, rattachements contrôlés → 422),
  PATCH (sku/barcode corrigeables, `null` retire un rattachement, `isActive` exige `product.disable`),
  audit CREATE/UPDATE dans la transaction. `setPrice` reste 501.
- Catégories (`catalog.service.ts`) : liste plate, création, **PATCH** ; 2 niveaux ; nom unique par
  parent sans la casse sous verrou consultatif.
- Emplacements (`locations/` sorti du module contrat) : liste, création EMPLACEMENT seulement (rattaché
  au dépôt, code `A-02-04-03` et nom dérivés), **PATCH** (EMPLACEMENT seulement).
- `GET /pricing/tiers`, `GET /pricing/tax-rates`.
- `GET /catalog/changes?cursor=&limit=` : curseur opaque `(updatedAt,id)` par type, inactifs compris,
  `hasMore`, lignes servies après 5 s de stabilisation (`CATALOG_SETTLE_MS`, limite notée `ponytail:`).
- `backend/test/catalog.e2e-spec.ts` : **27 tests** (génération concurrente, code squatté, clé fausse,
  matrice 3 rôles, catégories concurrentes, emplacements, atomicité audit, delta paginé au même instant).
Preuve : `tsc` OK · lint propre sur les fichiers touchés · `npm test` → **9 suites, 60 passed** ·
`npm run test:e2e` → **6 suites, 116 passed**. Contre-épreuve : saut du code interne squatté retiré → test en échec.
- Test instable corrigé (`users-audit` « deux admins qui se retirent MUTUELLEMENT ») : le perdant peut
  recevoir **401** (sa session vient d'être révoquée par la désactivation, lue en parallèle du compte) —
  refus correct, le test acceptait seulement 403/409.
> ⚠️ **Docker réinitialisé le 2026-09-14** : le disque de données Docker a été recréé (images, conteneurs,
> volumes perdus — dont `infinit-school-*`). Base de dev repartie de zéro sur **5432** (`migrate deploy` +
> `npm run seed`). Si Docker Desktop refuse de démarrer (« running com.docker.build: exit status 1 ») :
> tuer le `com.docker.build.exe` orphelin, puis relancer Docker Desktop.
**App — FAITE (commit `391d545`)** :
- Drift **schéma v3** : table unique `CatalogEntries` (ressource JSON + colonnes de tri/recherche),
  migration v2→v3 testée.
- `features/catalog/` : `data/` (modèles freezed, `CatalogApi`, `CatalogRepository` : `pull()` paginé,
  chaque page écrite AVEC son curseur dans une transaction), `application/` (sync cache-first, filtres,
  flux Drift, `CatalogActions` en ligne, `changedFields`), `presentation/` : `CatalogScreen` à sections
  Produits / Catégories (ADMIN) / Emplacements (ADMIN+MAGASINIER) — une seule destination « Catalogue »,
  l'admin garde 4 onglets ; tableau desktop, lignes mobiles ; `ProductForm` (lecture seule sans
  `product.write`), `CategoryForm`, `LocationForm`.
- `ui/widgets/form_panel.dart` : cadre de formulaire partagé (panneau latéral / plein écran).
- Saisie code-barres = champ texte (douchette USB) ; scan caméra = P1 n°13.
Preuve : `flutter analyze` → No issues found! · `flutter test` → **+159 ~17** All tests passed.
Contre-épreuve : échappement LIKE retiré → test en échec.
Captures (6 nouvelles, 12 à 17) relues par l'agent : 3 défauts corrigés (flèches des listes déroulantes
en carré — icône Lucide ; aide du code-barres tronquée ; code d'emplacement trop petit).
**Audits (2026-09-14)** — `security-reviewer` : **NON CONFORME** (0 critique, 2 importants, 5 mineurs) ;
`reviewer` : **PAS OK, aucun bloquant** (3 à corriger + suggestions). Corrigé, testé, contre-éprouvé :
- I1 (sécu) : UUID en MAJUSCULES dans un corps → une catégorie devenait son propre parent. Décorateur
  `IsCanonicalUuid()` (`common/validation.ts`) sur tous les UUID des DTO catalogue (e2e + contre-épreuve).
- M1 : curseur forgé (id de tirets, date hors plage PostgreSQL) → 500 ; désormais 400 (`isUUID`, date bornée).
- M2 : catégories et emplacements audités (CREATE/UPDATE, avant/après) ; PATCH sans changement → pas d'audit.
- M3 + revue n°2 : verrou pris AVANT toute lecture dans les écritures de catégories (déplacements croisés →
  jamais 3 niveaux) ; verrou d'écriture produits (référence unique sans la casse, `ponytail:` noté).
- revue n°1 (app) : « Toutes les catégories » ne retirait jamais le filtre (Flutter traite `null` comme une
  annulation) → valeur sentinelle + test d'écran.
- revue n°3 : `@MaxLength(20)` sur les seuils ; `barcode` borné à 64.
- suggestions appliquées : garde de version locale (Drift **v4**, colonne `updatedAt` : une page de delta en
  retard n'écrase plus une fiche plus récente) ; recherche locale sans accents.
Preuve : backend `tsc` OK · **60** unitaires · **122** e2e (33 catalogue) ; app analyze propre · **+163 ~17**.

⏳ **EN ATTENTE DE DÉCISION MEDMEDBEN — I2 (sécu, important)** : `lastPurchasePriceHt` (coût d'achat = base
de la marge) est envoyé à TOUS les rôles (liste, fiche, delta) et stocké sur le poste. Aucun code ne
l'alimente encore (feature Réceptions). À trancher : qui voit le coût ? Puis filtrer DTO + delta selon le
rôle, et purger/re-télécharger le catalogue local quand le compte change (`CatalogEntries` et
`catalog.cursor` sont partagés par poste). M4 (`mainSupplierId` visible du vendeur, négligeable) suit la
même décision. M5 : ajouter `FreshAccessGuard` sur `POST /products/:id/prices` quand la route sortira du 501.
Notes pour plus tard : refuser un changement d'unité si des mouvements de stock existent (feature Stock) ;
la descente devra transporter `ProductPrice` (feature Ventes).

**Reprise ICI** : décision I2 → correctif → relecture humaine des captures 12-17 → cocher `docs/plan.md` → P0 #3.

### ▶️ ENSUITE
Feature **P0 #2** — plan détaillé ci-dessous, contrat backend figé (routes 501).

### 📋 Plan de la P0 #2 — Produits + catégories + emplacements + codes-barres (préparé, non commencé)
Contrat existant (routes 501) : `products.controller.ts`, `locations.controller.ts`. Ajustements prévus :
1. **Backend**
   - Migration additive : séquence PostgreSQL `product_internal_barcode_seq`.
   - `common/barcode/` : code interne **EAN-13 préfixe `20`** (préfixe « usage interne » GS1, jamais
     porté par un produit fabricant) + 10 chiffres de séquence + clé ; contrôle de clé des GTIN
     saisis (8/12/13 chiffres) ; retry sur collision (contrainte unique) — règle 15.
   - Produits : liste paginée `{data, meta}` (le contrat renvoie un tableau nu → corrigé), recherche
     nom/SKU/code-barres/marque, filtres catégorie + inactifs, tri whitelisté ; création (ADMIN,
     `product.write`, id client accepté) ; PATCH (sku/barcode corrigeables, `isActive` exige
     `product.disable`) ; audit create/update ; `setPrice` reste 501 (feature Ventes/tarifs).
   - Catégories : liste plate (le client fait l'arbre), création, **PATCH à ajouter** ; 2 niveaux
     (catégorie → sous-catégorie), nom unique par parent (sans casse).
   - Emplacements : seuls les `EMPLACEMENT` se créent (MAGASIN/DEPOT/TRANSIT = uniques, seed) ;
     code dérivé `A-02-04-03` si absent ; **PATCH à ajouter** (renommer, désactiver).
   - Référentiels en lecture : `GET /pricing/tax-rates`, `GET /pricing/tiers` (le formulaire produit
     choisit la TVA).
   - **Descente delta du catalogue** (`docs/context.md` : catalogue complet en local, delta only) :
     `GET /api/catalog/changes?cursor=` → produits/catégories/emplacements/TVA modifiés depuis un
     curseur opaque `(updatedAt, id)` par type (robuste aux mises à jour de masse au même instant),
     inactifs compris, pages bornées + `hasMore`.
2. **App** : `features/catalog/` (data/application/presentation{desktop,mobile}) ; Drift v3 (tables
   catalogue + curseur) ; lecture **cache-first** ; écrans Produits (tableau desktop SKU mono /
   liste mobile), fiche produit (lecture pour tous, édition ADMIN), Catégories (ADMIN),
   Emplacements (ADMIN + MAGASINIER) ; onglet mobile « Plus » au-delà de 4 destinations (§7).
   Saisie code-barres : champ texte (douchette USB = clavier) — le scan caméra est la P1 n°13.
3. **Tests** : unitaires (EAN-13, curseur), e2e (CRUD, matrice des 3 rôles, génération unique +
   collision, règles catégories/emplacements, delta), app (dépôt local, écrans, formulaires).

## Relais précédent (MEDMEDBEN, 2026-09-10) — conservé pour l'historique
- Date : 2026-09-10 · Qui : **MEDMEDBEN** · Session interrompue (budget de tokens)

### ✅ FAIT ET PROUVÉ

**B. Dette AuditLog — SOLDÉE.**
`backend/src/users/users.service.ts` réécrit : chaque mutation sensible (création, changement de
rôle/permissions, activation/désactivation, reset de mot de passe, révocation) s'exécute dans un
`prisma.$transaction` et écrit son `AuditLog` DANS la même transaction (règles 3 et 7).
- Acteur pris via `@CurrentUser()` + IP via `@Ip()` → `ActorContext` (`users.controller.ts`).
- `auditSnapshot()` ne sérialise JAMAIS `passwordHash` ni un mot de passe : le journal est
  lisible par l'admin, il ne doit pas devenir une fuite. Un reset ne trace que le FAIT du reset.
- `revokeAllInTx()` duplique volontairement `AuthService.revokeAllForUser` : ce dernier utilise sa
  propre connexion et casserait l'atomicité.

**A. Écrans (design AMPÈRE appliqué) — faits :**
- `ui/theme/ampere_colors.dart` : `ThemeExtension` avec les **4 palettes** (§2.1-§2.4) — desktop et
  mobile n'ont pas les mêmes valeurs, la palette suit la LARGEUR d'écran (`main.dart` builder).
- `ui/theme/ampere_typography.dart` : échelles §3.1/§3.2 + géométrie §4 (rayons, cibles tactiles).
- `ui/theme/app_theme.dart` : `AppTheme.mobile(dark:)` / `AppTheme.desktop(dark:)`.
- `ui/theme/theme_controller.dart` : thème **persisté** en `LocalSettings` (Drift), sombre par défaut.
- Police **Archivo** variable bundlée : `app/fonts/Archivo-Variable.ttf` (+ `OFL.txt`), déclarée
  dans `pubspec.yaml`. Icônes **Lucide** (`lucide_icons_flutter`).
- `ui/widgets/screen_state.dart` refait : 7 états (dont `noResults`), **squelettes** au chargement
  (§8 interdit la roue centrée), `SyncIndicator`, `AmpereBadge`, `AmpereIconChip`,
  `AmpereFieldLabel`, `AmpereInlineAlert`.
- Écrans : `login_screen.dart` (refait), `change_password_screen.dart` (refait — gère **forcé ET
  volontaire** via `forced:`), `profile_screen.dart` (**nouveau** : identité, rôles, changement de
  mot de passe, « déconnecter tous mes appareils », bascule de thème, déconnexion).
- Gestion utilisateurs ADMIN (**nouveau**) : `features/users/` — `users_controller.dart`,
  `users_screen.dart` (liste, recherche, badges, menu d'actions : modifier / activer-désactiver /
  reset mot de passe / révoquer sessions), `user_form_sheet.dart` (création + édition + choix du
  rôle parmi les 3 figés).
- Data : `data/api/users_api.dart`, `data/models/user_models.dart`, provider `usersApiProvider`.
- Shells recâblés : `desktop_shell.dart` (sidebar 246 px, barre 56 px, bascule thème),
  `mobile_shell.dart` (onglets par rôle, badge sync permanent). L'entrée « Utilisateurs »
  n'apparaît que pour l'ADMIN.

### Preuves réelles (sorties collées)
```
$ cd backend && npm test
Test Suites: 4 passed, 4 total · Tests: 33 passed, 33 total

$ npm run test:e2e
PASS test/users-audit.e2e-spec.ts   <-- NOUVEAU (9 tests)
PASS test/sync.e2e-spec.ts
PASS test/auth.e2e-spec.ts
Test Suites: 3 passed, 3 total · Tests: 43 passed, 43 total

  Audit de la gestion des comptes (e2e)
    √ la création d'un compte est tracée, avec son auteur
    √ la trace ne contient JAMAIS de mot de passe
    √ un changement de RÔLE est tracé avec l'avant et l'après
    √ une désactivation est tracée
    √ une réinitialisation de mot de passe est tracée sans le secret
    √ une révocation de sessions est tracée avec leur nombre
    √ une mutation REFUSÉE n'écrit AUCUNE trace (atomicité)
    √ désactiver le DERNIER admin actif est refusé, et ne trace rien
    √ l'audit reste réservé à l'ADMIN

$ cd app && flutter analyze
No issues found!          (0 error, 0 warning, 0 info)

$ flutter test
00:05 +86: All tests passed!     (86 tests, dont 8 nouveaux sur users_screen)
```

### ⛔ CE QU'IL RESTE À FAIRE (reprise ICI)

1. **`flutter build windows --release` : NON EXÉCUTÉ cette session** (interrompu volontairement).
   Le mode développeur Windows est désormais actif, mais le blocage précédent était le composant
   **ATL de Visual Studio** (`fatal error C1083: 'atlstr.h'`), exigé par
   `flutter_secure_storage_windows`. Prérequis : libérer de l'espace sur `C:` (il restait ~1,0 Go)
   puis ajouter `Microsoft.VisualStudio.Component.VC.ATL` via Visual Studio Installer.
   **Le noter ici sans le contourner** si ça ne passe toujours pas.
2. **Audit `security-reviewer`** sur cette feature : **PAS ENCORE LANCÉ** (obligatoire avant de
   marquer la feature terminée — `CLAUDE.md` § Méthodologie 5).
3. **Revue `reviewer`** : pas encore lancée.
4. Cocher la checklist de la feature dans `docs/plan.md`.
5. Vérification manuelle humaine (capture d'écran) — critère « tâche terminée ».

### 🎨 DESIGN SYSTEM — NOUVEAU DOCUMENT, À LIRE AVANT TOUT ÉCRAN

**`docs/design-system.md` (AMPÈRE)** a été ajouté et **fait foi pour l'APPARENCE**.
Portée : couleurs, typographie (**Archivo**), espacements, rayons, icônes (**Lucide**), aspect des
composants et des états, thème **sombre par défaut** + clair.
**Il ne change AUCUNE logique** : rôles (3, figés), schéma, permissions, numérotation, workflows
restent régis par `CLAUDE.md` / `spec-fonctionnelle.md` / `permissions.md` / `context.md`.
**En cas de contradiction, la logique du projet gagne.**

Déjà implémenté et à RÉUTILISER — ne pas réinventer un thème :
| Besoin | Où |
|---|---|
| Jetons de couleur (4 palettes §2.1-§2.4) | `app/lib/ui/theme/ampere_colors.dart` → `AmpereColors.of(context)` |
| Typographie §3 + géométrie §4 | `app/lib/ui/theme/ampere_typography.dart` (`AmpereType`, `AmpereGeometry`) |
| ThemeData | `app/lib/ui/theme/app_theme.dart` → `AppTheme.mobile(dark:)` / `AppTheme.desktop(dark:)` |
| Thème persisté | `app/lib/ui/theme/theme_controller.dart` (`themeModeProvider`) |
| États d'écran, badges, pastilles, alertes | `app/lib/ui/widgets/screen_state.dart` |

⚠️ La palette suit la **largeur d'écran** (desktop ≠ mobile), choisie dans le `builder` de
`main.dart`. Un widget ne lit JAMAIS le thème : il lit `AmpereColors.of(context)`.

### ▶️ OÙ REPRENDRE EXACTEMENT

Tout le code ci-dessus est **committé, compile, analyse propre, tests verts**. Il ne reste
QUE les points 1 à 5 de la liste précédente pour clore la feature P0 #1. **Aucun code métier
n'est à réécrire.** Ensuite → feature P0 #2 (Produits + catégories + emplacements + codes-barres),
dont le contrat backend est déjà figé (routes 501 dans `api-contract.module.ts`).

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
| **Auth + utilisateurs (P0 #1)** | 🟢 **Close** (build Windows : prérequis ATL machine) | 🟢 Complet, durci (3 tours d'audit) | 🟢 Validé par MEDMEDBEN | 🟢 55 unit + 89 e2e · 147 app | 🟢 CONFORME |
| Produits + catégories + emplacements | 🟡 **~85 %** — audits + relecture humaine | 🟡 Contrat figé (501) | — | — | — |
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
- **Permissions « à la carte »** (2026-09-11, bloquant de la contre-revue P0 #1) : liste des
  permissions réellement attribuables par rôle, ou cumul par les rôles seulement ? Voir « Ce qu'il
  reste à faire », point 3. MEDMEDBEN + Ratybox.
- **Séparation des tâches** : `stock.adjust.validate`, `inventory.validate` et `sale.cancel` ne sont
  pas dans `ADMIN_ONLY_PERMISSIONS` — un magasinier pourrait se voir accorder la validation de ses
  propres ajustements. À confirmer (contre-audit sécurité, point 4).
- **`CONVENTIONS.md` réécrit le 2026-09-11** (structure Flutter : `data/` dans la feature,
  `presentation/{desktop,mobile}`, `lib/data` = infrastructure partagée) : à valider par MEDMEDBEN.
