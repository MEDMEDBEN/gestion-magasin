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

### Sync
- Endpoint de sync idempotent (dédup sur `client_mutation_id`), validation qui peut rejeter (voir `docs/context.md`). Toute mutation offline passe par ce chemin.

## Frontend (Flutter)

### Structure d'une feature (identique pour toutes)
```
lib/features/<feature>/
├── data/         ← repository, DTO (Freezed), source distante (Dio) + locale (Drift)
├── domain/       ← modèles métier, use cases si nécessaire
├── application/  ← providers Riverpod (state), controllers
└── presentation/
    ├── desktop/  ← écrans desktop
    └── mobile/   ← écrans mobile
```
- **Logique métier partagée** dans `lib/core/` — 100 % commune desktop/mobile.
- **State** : Riverpod (`AsyncNotifier`/`Notifier`). Pas de logique dans les widgets.
- **Modèles** : Freezed + json_serializable, alignés sur les DTO du backend.
- **HTTP** : un seul client Dio configuré (base URL, intercepteur JWT + refresh, gestion 401). Pas d'appel HTTP hors repository.
- **Local/offline** : Drift ; toute écriture offline crée une entrée dans la file de mutations. Lecture **cache-first** puis rafraîchissement.
- **États d'écran** : chaque écran gère `Loading / Empty / Error / Success / Offline / SyncPending`.

## Génération de fichiers (une seule lib par besoin)

Pour éviter que deux agents utilisent des outils différents pour le même besoin :
- **PDF** (ticket, facture, devis, bons, rapports) : générés **côté serveur** à partir de templates HTML rendus en PDF. **Choisir UN moteur** (ex : HTML→PDF via le Chromium déjà présent, ou `pdfkit`) et le centraliser dans `backend/src/common/pdf/`. Ne pas mélanger deux moteurs.
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
