# État d'avancement

> Les deux devs travaillent à des heures différentes, jamais en simultané — ce fichier EST le relais.
> Règle stricte : `git pull` + lire ce fichier en entier AVANT de coder. Le mettre à jour + `git push` avant de fermer.
> **Signer par NOM** (MEDMEDBEN / Ratybox), plus par rôle : on se signait tous les deux « Dev A ».

## Phase actuelle
`Phase 0` **TERMINÉE**. En cours : **FEATURE P0 #1 — Auth + utilisateurs**, ~85 % faite.

## Relais en cours — 2026-09-11 · **Ratybox** (session Claude Opus 5)

> Section tenue à jour au fil de la session. Reprise : lire d'abord ce bloc.

- **Outillage aligné** : Flutter **3.44.8** / Dart 3.12.2 (même révision que MEDMEDBEN,
  `058e0af2c2`). Machine macOS : `flutter build windows` y est **impossible** (« only supported
  on Windows hosts ») — le point 1 ci-dessous reste à faire sur le poste Windows, sans contournement.
- **Audits lancés** : `security-reviewer` → **NON CONFORME** (1 critique, 4 importants, 11 mineurs) ;
  `reviewer` → **PAS OK** (3 bloquants, 17 à corriger, 17 suggestions). Tout est corrigé, un test
  par correctif.
- ✅ **Backend corrigé** (commit `d7c6c95`) : 55 tests unitaires + **76 e2e** verts. Détail dans
  le message de commit (C1, I1, I4, M1-M8, C1-C7 revue…).
- ✅ **App corrigée** (commit `ae8c16e`) : 140 tests, `flutter analyze` vierge. I2, I3, M6, M7,
  M9, M10, B2, B3, C9-C16 + suggestions. Structure CONVENTIONS appliquée (et CONVENTIONS.md
  clarifié), décisions consignées dans `docs/context.md` (journal 2026-09-11).
- ✅ **Vérification visuelle** (commit `360a488`) : 11 écrans rendus avec les vraies polices —
  a révélé 2 défauts corrigés (boutons pas en Archivo → Segoe UI sous Windows ; bande d'ombre
  noire du panneau). Outil réutilisable : `flutter test test/tools/screen_captures_test.dart
  --dart-define=CAPTURE_OUT=<dossier>`. Backend réel démarré : `/api/health`, 401/400 codés,
  logout public, refus de démarrer avec la clé JWT d'exemple — vérifiés au `curl`.
- ⏳ **Contre-audits `security-reviewer` + `reviewer` en cours** sur ces correctifs.

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

## Relais précédent
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
| **Auth + utilisateurs (P0 #1)** | 🟡 **~85 %** — reste build+audits | 🟢 Complet **+ AuditLog** | 🟢 Login · MDP · Profil · Gestion users | 🟢 43 e2e + 86 app | 🔴 **Audit à lancer** |
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
