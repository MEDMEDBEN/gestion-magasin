# État d'avancement

> Les deux devs travaillent à des heures différentes, jamais en simultané — ce fichier EST le relais entre vous deux.
> Règle stricte : `git pull` + lire ce fichier en entier AVANT de coder. Le mettre à jour + `git push` avant de fermer la session.
> Au retour, dire simplement "lis tasks.md et continue" plutôt que de reprendre l'historique complet.

## Phase actuelle
`Phase 0 — Fondation` (en cours — étape 1/6 terminée : schéma Prisma)

## Dernier relais
- Date : 2026-09-09
- Qui a travaillé : Dev A (backend & data)
- Ce qui a été fait : **étape 1 de la Phase 0 — fondation data**.
  - `git init` sur la branche `develop`, remote `origin` → `https://github.com/MEDMEDBEN/gestion-magasin.git`.
  - Backend NestJS initialisé dans `backend/` (TypeScript strict, CLI Nest v10 — la v11 exige Node ≥ 22.22, la machine tourne en 22.14).
  - Prisma 7.10.0 installé et configuré (`backend/prisma7.config.ts`, `DATABASE_URL` dans `backend/.env`, non commité).
  - Arborescence de modules créée conformément à `CLAUDE.md` (dossiers vides avec `.gitkeep` : auth, users, roles, products, inventory, stock, locations, transfers, sales, customers, purchases, suppliers, receptions, payments, planning, notifications, reports, problems, messaging, automation, audit, sync, storage, common).
  - `backend/prisma/schema.prisma` écrit avec les **35 tables exhaustives de la Phase 0** + 22 enums. Aucune logique métier, aucun endpoint.
  - `PrismaModule` / `PrismaService` câblés (infrastructure seulement) pour prouver que le client généré compile.
  - Infra de dev démarrée : `docker compose -f infra/docker-compose.dev.yml up -d` (PostgreSQL 16 + Redis 7 + MinIO).

### Preuves réelles (sorties collées)

Migration appliquée :
```
$ npx prisma migrate dev --name phase0_schema_initial
Prisma schema loaded from prisma\schema.prisma.
Datasource "db": PostgreSQL database "gestion_magasin_dev", schema "public" at "localhost:5432"
Applying migration `20260909024741_phase0_schema_initial`
The following migration(s) have been created and applied from new schema changes:
prisma\migrations/
  └─ 20260909024741_phase0_schema_initial/
    └─ migration.sql
Your database is now in sync with your schema.
```

Tables réellement créées en base (35 modèles + 3 tables de jointure implicites + `_prisma_migrations`) :
```
$ docker exec infra-postgres-1 psql -U dev -d gestion_magasin_dev -c "\dt"
AuditLog · CashMovement · CashSession · Category · Customer · CustomerPayment · Inventory
InventoryLine · InvoiceCounter · Location · Notification · Permission · PlanningTask
PriceTier · Product · ProductPrice · PurchaseLine · PurchaseOrder · Quote · QuoteLine
Reception · ReceptionLine · RefreshToken · Role · Sale · SaleLine · Stock · StockMovement
Supplier · SupplierPayment · SyncMutation · TaxRate · Transfer · TransferLine · User
_RolePermissions · _UserPermissions · _UserRoles · _prisma_migrations
(39 rows)
```

Types de colonnes vérifiés en base (règles 4 et 10 de `CLAUDE.md`) :
```
$ ... information_schema.columns ...
 CashSession   | openingFloat      | integer  | 32 | 0
 ProductPrice  | priceHt           | integer  | 32 | 0
 PurchaseLine  | unitPriceHt       | integer  | 32 | 0
 Sale          | totalTtc          | integer  | 32 | 0
 SaleLine      | quantity          | numeric  | 14 | 3
 Stock         | quantity          | numeric  | 14 | 3
 StockMovement | quantity          | numeric  | 14 | 3
 TaxRate       | rate              | numeric  |  5 | 2
 TransferLine  | requestedQuantity | numeric  | 14 | 3
```
→ **Tous les montants en `integer` (centimes), toutes les quantités en `numeric(14,3)`.**

Build et tests :
```
$ npm run build
> nest build          (aucune erreur)

$ npm test
PASS src/app.controller.spec.ts
Test Suites: 1 passed, 1 total
Tests:       1 passed, 1 total
```
(Le seul test est celui du scaffold Nest — les vrais tests arrivent avec l'auth et le stock.)

### Décisions de modélisation prises (à connaître avant de continuer)
- **`id`** : `String @id @default(uuid(7)) @db.Uuid` partout — le serveur génère un UUIDv7 par défaut, mais le client **peut fournir le sien** (contrat de sync `docs/context.md` §1).
- **`StockMovement`** : `locationId` + `quantity` **signée** = le couple qui fait autorité sur la projection (règle 2). `sourceLocationId` / `destinationLocationId` sont conservés mais **informatifs** (traçabilité d'un transfert), conformément à la liste de champs de `spec-fonctionnelle.md` §31. Un transfert produit donc **deux** mouvements (`TRANSFERT_SORTIE` puis `TRANSFERT_ENTREE`), jamais un seul à deux faces.
- **`Location`** : une seule table pour deux usages, distingués par `type` — `MAGASIN` / `DEPOT` / `TRANSIT` portent les projections de stock ; `EMPLACEMENT` = position physique au dépôt (`zone`/`aisle`/`shelf`/`position`, rattachée au DEPOT par `parentId`). `Product.storageLocationId` pointe vers un `EMPLACEMENT`.
- **Dettes jamais stockées** : pas de champ « reste dû ». Client → `Sale.totalTtc − Sale.paidAmount − Σ CustomerPayment`. `Sale.paidAmount` = encaissement au moment de la vente ; les règlements ultérieurs sont des `CustomerPayment`.
- **`InvoiceCounter`** : porte **tous** les compteurs séquentiels par année via `documentType` (`FACTURE`, `DEVIS`, `BON_COMMANDE`, `TRANSFERT`), contrainte `@@unique([documentType, year])` — un seul mécanisme pour `FAC-2026-00001`, `DEV-…`, `BC-…`, `TRF-…`.
- **Idempotence sync** : `clientMutationId` (UUID, `@unique`) présent sur `Sale`, `CustomerPayment`, `Reception`, `Transfer`, `Inventory` — les entités créables hors-ligne — en plus de la table `SyncMutation`.
- **`PlanningTask.EN_RETARD`** n'est **pas** un statut stocké : il se calcule (`dueDate` dépassée + statut ≠ `TERMINEE`), conformément à `docs/plan.md`.
- **Références polymorphes** (`StockMovement.operationId`, `Notification.operationId`) : pas de FK, typées par l'enum `OperationType` + index composite.

### Points d'attention pour la suite
- La CLI Nest est figée en **v10** (Node 22.14 sur la machine). Ne pas la mettre à jour sans monter Node ≥ 22.22.
- Prisma 7 utilise **`prisma7.config.ts`** (et non `prisma.config.ts`) ; `DATABASE_URL` est lu depuis `backend/.env` via `dotenv`. `backend/.env` est **gitignoré** — chaque dev crée le sien (valeur dev : `postgresql://dev:dev@localhost:5432/gestion_magasin_dev?schema=public`).
- Le client Prisma est généré dans `backend/generated/prisma` (gitignoré) → lancer `npx prisma generate` après un `git pull` qui touche le schéma.
- `prisma init` dépose des dossiers `.agents/`, `.claude/`, `.windsurf/` et `skills-lock.json` dans `backend/` : ils sont **gitignorés**, ne pas les committer.

- État exact du code : `backend/` compile et ses tests passent ; schéma complet migré en base de dev. **Aucun endpoint, aucun guard, aucune logique métier** — c'était volontaire pour cette étape. `app/` (Flutter) n'existe pas encore.
- Bloqué sur : rien.
- **Prochaine étape précise** (étape 2 de la Phase 0) :
  1. **Contrat OpenAPI** des endpoints P0 (forme uniquement, pas d'implémentation) : installer `@nestjs/swagger`, l'exposer sur `/api/docs` depuis `backend/src/main.ts`, et poser les DTO de requête/réponse selon `CONVENTIONS.md` (pagination `{ data, meta }`, enveloppe d'erreur `{ statusCode, message, error, code? }`, enum `common/error-codes.ts`).
  2. **Auth JWT** dans `backend/src/auth/` : login (argon2), access 15 min + refresh 90 j glissant stocké **hashé** dans `RefreshToken`, révocation, `mustChangePassword` à la première connexion, `RolesGuard` + décorateur `@Roles(...)` dans `backend/src/common/`.
  3. **Seed** (`backend/prisma/seed.ts`) : 3 rôles (`ADMIN`, `VENDEUR`, `MAGASINIER`) + permissions de `docs/permissions.md` + les `Location` `MAGASIN` / `DEPOT` / `TRANSIT` + un `PriceTier` `DETAIL` par défaut + un `TaxRate` 19 % + un compte admin initial.
  4. **Socle de sync** dans `backend/src/sync/` : endpoint `POST /sync` idempotent (dédup sur `SyncMutation.clientMutationId`), validation qui peut **REJETER** (anti-stock-négatif), renvoi du résultat mémorisé sur retry.
  5. Faire **valider la matrice de permissions** `docs/permissions.md` par l'utilisateur **avant** d'écrire les guards (décision humaine, cf. `docs/plan.md`).
  6. Ensuite seulement : `app/` (structure Flutter de base).

  > Rappel : **ne commencer aucune feature P0** tant que les 6 cases de la Phase 0 ne sont pas cochées.

## Avancement par feature

| Feature | Statut | Backend | Frontend | Tests | Sécurité |
|---|---|---|---|---|---|
| Phase 0 — Fondation (schéma + OpenAPI + auth + socle sync) | 🟡 En cours | 🟢 Schéma Prisma migré (35 tables) · 🔴 OpenAPI / auth / sync | — | — | — |
| Auth + rôles/permissions | 🔴 Non commencé | — | — | — | — |
| Produits + catégories + emplacements | 🔴 Non commencé | — | — | — | — |
| Stock + mouvements | 🔴 Non commencé | — | — | — | — |
| Ventes (tarifs, TVA/facture, caisse) + dettes clients + paiements | 🔴 Non commencé | — | — | — | — |
| Fournisseurs + clients + dettes fournisseurs | 🔴 Non commencé | — | — | — | — |
| Achats | 🔴 Non commencé | — | — | — | — |
| Réceptions (dont partielles) | 🔴 Non commencé | — | — | — | — |
| Transferts magasin↔dépôt | 🔴 Non commencé | — | — | — | — |
| Inventaire + tournant | 🔴 Non commencé | — | — | — | — |
| Planning hebdomadaire | 🔴 Non commencé | — | — | — | — |
| Historique/audit | 🔴 Non commencé | — | — | — | — |
| Génération PDF/Excel, devis, étiquettes code-barres (P1) | 🔴 Non commencé | — | — | — | — |
| Socle offline/sync appliqué au P0 | 🔴 Non commencé | — | — | — | — |

Légende : 🔴 non commencé · 🟡 en cours · 🟢 terminé et prouvé

## Décisions en attente
- Matrice de permissions CRUD détaillée par entité (à produire et valider en Phase 0).
- Confirmer les canaux de notification temps réel (WebSocket) au moment de la feature Notifications (P1).
