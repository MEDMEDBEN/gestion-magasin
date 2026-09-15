# CONVENTIONS.md — conventions de code (à respecter par TOUS les devs/agents)

But : garantir que le code écrit par un agent/session soit **indiscernable** de celui écrit par l'autre. Le subagent `reviewer` vérifie ces conventions à chaque commit. En cas de doute, imiter le code existant plutôt que d'introduire un nouveau style.

## Règles transverses
- **Langue** : code et identifiants en anglais ; commentaires et messages métier en français si utile.
- **Argent** : type `Money` = entier en centimes (Prisma `Int`/`BigInt`, Dart `int`). Un seul utilitaire de formatage (`formatDA`). Jamais de `float`.
- **Quantités** : `Decimal` (Prisma `Decimal(14,3)`, Dart via `Decimal` package). Jamais d'arithmétique flottante sur les quantités.
- **IDs** : UUID (v7) générés côté client pour les entités créables hors-ligne. Clé primaire = `id: String @db.Uuid`.
- **Dates** : UTC en base et en transport (ISO 8601) ; conversion au fuseau local uniquement à l'affichage.
- **Enums** : valeurs en MAJUSCULES, identiques backend/DB/Flutter (voir machines à états dans `docs/plan.md`).

## Backend (NestJS)

### Structure d'un module (identique pour tous)
```
src/<feature>/
├── <feature>.module.ts
├── <feature>.controller.ts     ← routes + guards + swagger, AUCUNE logique métier
├── <feature>.service.ts        ← logique métier + transactions Prisma
├── dto/                        ← *.dto.ts (class-validator), un DTO par requête/réponse
└── <feature>.spec.ts / test/   ← tests
```
- **Le controller ne contient jamais de logique métier** — il valide, appelle le service, mappe la réponse.
- **Les transactions** (`prisma.$transaction`) vivent dans le service. Toute opération composée (vente, réception, transfert, ajustement) est atomique.

### DTO & validation
- Chaque payload entrant a un DTO avec `class-validator` (`@IsUUID`, `@IsInt`, `@IsDecimal`, `@Min`…). Rien n'est lu depuis `body` sans DTO.
- Chaque réponse a un DTO/type de sortie explicite (pas de renvoi direct d'entité Prisma avec champs sensibles).

### Format de réponse & erreurs
- **Succès** : renvoyer directement la ressource ou `{ data, meta }` pour les listes (voir pagination). Pas d'enveloppe `{ success: true }` partout.
- **Erreurs** : `HttpException` NestJS, format uniforme `{ statusCode, message, error, code? }`. `code` = code métier stable pour le client (ex : `STOCK_NEGATIVE`, `INVOICE_ONLINE_ONLY`, `CASH_SESSION_REQUIRED`).
- **Codes métier stables** définis dans une enum partagée `common/error-codes.ts` — le front s'y réfère, jamais au texte du message.

### Pagination (obligatoire sur toute liste)
- Query : `?page=1&limit=50&sort=field:asc&q=...`
- Réponse : `{ data: [...], meta: { page, limit, total } }`
- Limite par défaut 50, max 200.

### Sécurité
- Chaque route protégée par un guard de rôle explicite (`@Roles('ADMIN', ...)` + `RolesGuard`). Voir `docs/permissions.md`.
- Aucune vérification de permission uniquement côté UI.
- Route rare et sensible (gestion des comptes, et demain prix/validations) : ajouter
  `@UseGuards(FreshAccessGuard)` — l'accès est relu EN BASE, pas seulement dans le token.
- Identifiants (email/téléphone) normalisés via `common/identifiers.ts` ; tout champ texte a un
  `@MaxLength` ; sur un PATCH, `@IsOptionalNotNull()` (jamais `@IsOptional()` qui laisse passer `null`).
- Tri de liste : `parseSort(query.sort, CHAMPS_AUTORISÉS, défaut)` — liste blanche obligatoire.

### Audit & configuration
- Toute action sensible écrit son `AuditLog` via `writeAudit(tx, actor, entry)` **dans la
  transaction de la mutation** ; jamais de secret dans le journal.
- Configuration validée au démarrage (`common/env.ts`) ; une limite se lit avec `intFromEnv()`.
- `configureApp()` (`common/app-setup.ts`) est partagé par `main.ts` ET les tests e2e
  (`test/helpers/e2e-app.ts`) : les tests éprouvent la configuration de production.

### Sync
- Endpoint de sync idempotent (dédup sur `client_mutation_id`), validation qui peut rejeter (voir `docs/context.md`). Toute mutation offline passe par ce chemin.
- **Rendre une opération synchronisable = écrire un handler, jamais toucher au moteur.** Créer
  `src/sync/handlers/<operation>.handler.ts` implémentant `SyncMutationHandler` (type d'opération,
  permissions exigées — les MÊMES qu'en ligne —, entité auditée, `validate()` du payload via un DTO
  dédié dans `src/sync/dto/`, `apply()` dans la transaction fournie), puis l'inscrire dans
  `SYNC_MUTATION_HANDLERS` (`src/sync/sync.module.ts`). `apply()` reçoit la transaction du moteur :
  lever une `BusinessException` = rejet, rien n'est appliqué.
- **Tout mouvement de stock passe par `StockLedgerService.applyMovement()`** (`src/stock/`), en ligne
  comme hors-ligne : c'est lui qui tient la règle 2 (mouvement source de vérité + projection dans la
  même transaction) et l'anti-stock-négatif. Ne jamais écrire `Stock.quantity` ailleurs.

## Frontend (Flutter)

### Structure d'une feature (identique pour toutes)
```
lib/features/<feature>/
├── data/         ← client d'API de la feature (Dio via `dioClientProvider`) + son provider,
│                   modèles Freezed (miroirs des DTO), source locale Drift si besoin
├── domain/       ← modèles métier, use cases — UNIQUEMENT si nécessaire (pas de dossier vide)
├── application/  ← providers Riverpod (state), controllers
└── presentation/
    ├── <écran>.dart  ← point d'entrée de l'écran + widgets communs desktop/mobile
    ├── desktop/      ← mises en page propres au desktop (tableau dense…)
    └── mobile/       ← mises en page propres au mobile (lignes tactiles…)
```
- **`lib/data/` = infrastructure PARTAGÉE uniquement** : client Dio unique, base Drift, file de
  mutations, moteur de sync, stockage des tokens, réglages locaux (`LocalSettingsStore`), modèles
  transverses (`PageMeta`, sync). Ce qui n'appartient qu'à une feature vit dans sa feature.
  (Clarifie `CLAUDE.md` § Structure : `data/` y désigne cette infrastructure commune.)
- **Logique métier partagée** dans `lib/core/` — 100 % commune desktop/mobile.
- **State** : Riverpod (`AsyncNotifier`/`Notifier`). Pas de logique dans les widgets. Les données
  propres à un écran sont `autoDispose` et dépendent de `currentUserIdProvider` : rien de la session
  précédente ne reste en mémoire sur un poste partagé.
- **Modèles** : Freezed + json_serializable, alignés sur les DTO du backend.
- **HTTP** : un seul client Dio configuré (base URL, intercepteur JWT + refresh, gestion 401,
  signal de joignabilité). Pas d'appel HTTP hors client d'API ; erreurs traduites par `guardApi()`.
- **Local/offline** : Drift ; toute écriture offline crée une entrée dans la file de mutations,
  **avec son auteur** (`authorUserId`) — une mutation ne part qu'avec la session de son auteur.
  Lecture **cache-first** puis rafraîchissement.
- **États d'écran** : chaque écran gère `Loading / Empty / Error / Success / Offline / SyncPending`.

### UI (design system AMPÈRE — `docs/design-system.md`)
- Couleurs **uniquement** via `AmpereColors.of(context)` ; typo/géométrie via `AmpereType` /
  `AmpereGeometry` ; aucune couleur en dur hors `ui/theme/ampere_colors.dart`.
- Points de rupture : `ui/breakpoints.dart` (mobile < 768 ≤ tablette < 1180 ≤ desktop).
- Menus : `ui/navigation.dart` est la SOURCE UNIQUE des destinations ; chaque condition est le
  miroir du guard serveur (rôle ET permission).
- Un écran hébergé dans une coquille n'a **pas d'`AppBar`** (la coquille porte le titre).
- Composants : `ui/widgets/screen_state.dart` (états, badges, alertes) et
  `ui/widgets/ampere_controls.dart` (bouton Danger, zone cliquable à focus visible, dialogue de
  confirmation destructive, panneau latéral). Saisie longue : panneau latéral (desktop) ou plein
  écran (mobile), jamais une feuille modale basse.
- Tests d'écran : remplacer les flux Drift (`pendingMutationsCountProvider`…) par des valeurs
  fixes — les flux réels ne se résolvent pas dans le temps simulé de `testWidgets`.

## Génération de fichiers (une seule lib par besoin)

Pour éviter que deux agents utilisent des outils différents pour le même besoin :
- **PDF** (ticket, facture, devis, bons, rapports) : générés **côté serveur** à partir de templates HTML rendus en PDF. **Choisir UN moteur** (ex : HTML→PDF via le Chromium déjà présent, ou `pdfkit`) et le centraliser dans `backend/src/common/pdf/`. Ne pas mélanger deux moteurs. **Choix fait (2026-09-15) : `pdfkit`** (`common/pdf/pdf.ts` → `renderPdf`), polices standard — pas de Chromium dans l'image. Côté app, impression/partage d'un PDF reçu : paquet `printing` uniquement.
- **Excel / CSV** : `exceljs`, centralisé dans `common/export/`.
- **Codes-barres** (image EAN-13 / Code128) : `bwip-js`, centralisé dans `common/barcode/`. La **génération du code interne** (si le produit n'en a pas) passe par un service unique qui garantit l'unicité (séquence + contrainte DB, retry sur collision).
- **Étiquettes** : composition (nom, prix, image code-barres) en PDF via le même moteur PDF ; deux gabarits — planche A4 et rouleau thermique.
- Documents volumineux archivés (factures) → MinIO ; sinon génération à la demande.

## Git
- Branche unique `develop` (voir CLAUDE.md).
- Commits : `<type>(<scope>): <résumé>` — types `feat, fix, refactor, test, docs, chore`. Ex : `feat(sales): validation + mouvements stock atomiques`.
- Un commit = une étape cohérente qui compile.

## Tests
- Priorité absolue : stock + argent + transitions d'état + permissions.
- Backend : unitaires (services) + intégration (flux vente→stock, réception→stock, transfert→stock, inventaire→ajustement, caisse→clôture).
- Toujours coller la sortie réelle des tests (jamais « ça devrait passer »).
