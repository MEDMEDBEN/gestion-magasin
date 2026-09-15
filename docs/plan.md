# Plan de développement

## Répartition de l'équipe

**Développeur A — Backend & Data**
Modules NestJS, schéma PostgreSQL/Prisma, sécurité serveur, moteur de sync serveur, WebSocket, doc API.

**Développeur B — Frontend Flutter (desktop + mobile)**
UI desktop et mobile, intégration API (Dio/Riverpod), moteur de sync offline (Drift), scanner code-barres.

**Zone partagée (à faire ENSEMBLE avant toute feature)**
- Schéma de données (Prisma)
- Contrat API (OpenAPI)
- Contrat de synchronisation offline (voir `docs/context.md`)
- Règles métier critiques (calcul de stock, transitions d'état)
- Matrice de permissions CRUD (voir plus bas)

## Phase 0 — Fondation (avant toute feature, obligatoire)

- [x] **Schéma Prisma complet P0** — liste exhaustive et figée des tables ci-dessous _(2026-09-09 — 35 tables migrées, preuve dans `docs/tasks.md`)_
- [x] Contrat OpenAPI complet pour tous les endpoints P0 (forme uniquement) _(2026-09-09 — 46 endpoints, 57 DTO, servi sur /docs)_
- [x] Auth JWT (login, refresh révocable via table `RefreshToken`, guards par rôle) fonctionnel _(2026-09-09 — 38 tests, audit sécurité passé)_
- [x] **Socle du contrat de sync** : UUID client, table de mutations, endpoint idempotent, validation serveur avec rejet (voir `docs/context.md`) _(2026-09-09 — `POST /api/sync`, 12 tests unitaires + 17 e2e, audit sécurité passé, preuve dans `docs/tasks.md`)_
- [x] Structure Flutter de base (navigation desktop/mobile, thème, client Dio configuré sur le contrat, base Drift + file de mutations) _(2026-09-09 — 73 tests Flutter, audit sécurité passé ; build desktop bloqué par un prérequis machine, voir docs/tasks.md)_
- [x] `docker-compose.dev.yml` local (PostgreSQL + Redis + MinIO) _(2026-09-09 — démarré et vérifié)_
- [x] **Matrice de permissions CRUD** des entités P0 validée par l'utilisateur _(2026-09-09 — voir docs/permissions.md)_

### Liste EXHAUSTIVE des tables de la Phase 0 (noms canoniques)

```
Auth / Users
  User, Role, Permission, RefreshToken

Catalogue
  Product, Category, Location
  (Product.barcode = unique ; génération interne via séquence si absent)

Stock
  Stock (projection), StockMovement (source de vérité)
  StockLossDeclaration (perte / casse ; celle du magasinier attend la validation admin — ajoutée en P0 n°3, migration additive)

Ventes
  Sale, SaleLine
  Customer, CustomerPayment
  Quote, QuoteLine (devis)

Tarifs / TVA
  PriceTier (détail, gros…), ProductPrice (prix par produit × tarif)
  TaxRate (taux de TVA) — ou champ tax_rate sur Product si un seul régime
  InvoiceCounter (compteur séquentiel des factures, par année)

Caisse
  CashSession (ouverture/clôture, fond, écart), CashMovement (encaissements/sorties)

Achats
  Supplier, SupplierPayment
  PurchaseOrder, PurchaseLine
  Reception, ReceptionLine

Transferts magasin ↔ dépôt
  Transfer, TransferLine

Inventaire
  Inventory, InventoryLine

Planning
  PlanningTask

Traçabilité / système
  Notification, AuditLog
  SyncMutation (file de mutations traitées côté serveur, pour l'idempotence)
```

> Entités P1 (à ajouter au schéma quand on arrive à la feature, pas en Phase 0 sauf si trivial) :
> `Conversation`, `Message` (communication interne), `Problem` (signalements).

### Conventions de nommage (figées — ne pas dévier)
- `PurchaseOrder` (pas `Purchase`) + `PurchaseLine`
- `Inventory` + `InventoryLine` (pas `InventoryCount`)
- `Reception` + `ReceptionLine`, `Transfer` + `TransferLine`, `Sale` + `SaleLine`
- Paiements : `CustomerPayment`, `SupplierPayment`

### Machines à états (figées)
- **PurchaseOrder** : `BROUILLON → COMMANDEE → CONFIRMEE → PARTIELLEMENT_RECUE → RECUE` (+ `ANNULEE`)
- **Transfer** : `DEMANDEE → ACCEPTEE → EN_PREPARATION → PREPAREE → EN_TRANSIT → RECUE` (+ `REFUSEE`, `ANNULEE`; préparation partielle gérée par les quantités de `TransferLine`)
- **Sale** : `VALIDEE` (+ `ANNULEE`) — pas de brouillon serveur ; le panier vit côté client jusqu'à validation. `Sale.type` : `TICKET` / `FACTURE` (la facture reçoit un numéro légal séquentiel serveur, voir CLAUDE.md règle 11)
- **CashSession** : `OUVERTE → CLOTUREE` ; `CashMovement.type` : `VENTE_ESPECES, ENTREE, SORTIE, PRELEVEMENT`
- **Quote (devis)** : `BROUILLON → ENVOYE → ACCEPTE → CONVERTI` (+ `REFUSE`, `EXPIRE`) — ne modifie jamais le stock
- **Inventory** : `EN_COURS → TERMINE` ; état de ligne : `CONFORME` / `ECART`
- **Problem** (P1) : `OUVERT → EN_COURS → RESOLU → FERME`
- **PlanningTask** : `A_FAIRE → EN_COURS → TERMINEE` (+ `EN_RETARD` calculé si échéance dépassée)
- **StockMovement.type** : `RECEPTION, VENTE, RETOUR_CLIENT, RETOUR_FOURNISSEUR, TRANSFERT_SORTIE, TRANSFERT_ENTREE, AJUSTEMENT_INVENTAIRE, PERTE_CASSE`

## Ordre des features (P0 → P3), une feature = une tranche verticale complète

### P0 — Cœur indispensable
1. Authentification + utilisateurs + rôles/permissions
2. Produits + catégories + emplacements + **codes-barres (capture si présent, sinon génération interne unique)**
3. Stock (quantités, mouvements traçables, projection atomique)
4. Ventes (recherche produit → panier → paiement → validation) + **tarifs (détail/gros)** + **TVA & ticket/facture (PDF)** + **caisse (ouverture/clôture, rapport Z)** + **dettes clients + paiements**
5. Fournisseurs + clients (fiches, historique) + **dettes fournisseurs + paiements**
6. Achats (commande fournisseur, statuts)
7. Réceptions fournisseurs (y compris partielles)
8. Transferts magasin ↔ dépôt (demande → préparation → transfert → réception)
9. Inventaire (comptage, écarts, ajustements) + inventaire tournant
10. Planning hebdomadaire
11. Historique global (audit trail)
12. Socle offline/sync appliqué aux opérations P0

### P1 — Important
13. Scanner code-barres (mobile)
14. Réception / préparation / inventaire mobiles
15. Dashboard (KPI + graphiques + alertes) desktop et mobile
16. Notifications (temps réel via WebSocket)
17. Communication interne (Conversation/Message)
18. Signalement de problème
19. Réapprovisionnement (seuils, suggestions)
20. Produits dormants / produits demandés
21. Rapports (ventes, stock, achats) + **exports Excel/CSV & PDF d'historique**
21a. **Devis** (création, PDF, conversion en vente)
21b. **Étiquettes code-barres** imprimables (nom, prix, code-barres — planche A4 / thermique)
21c. **Génération de documents PDF** (bon de livraison/transfert, bon de commande fournisseur) + **import** Excel/CSV (produits, clients, fournisseurs, stock initial)

### P2 — Avancé
22. Commande fournisseur préparée automatiquement + message par modèle (email/WhatsApp)
23. Contact clients ciblé par modèle
24. OCR factures / recherche photo (si pertinent)

### P3 — Futur
25. E-commerce
26. Intégrations supplémentaires

**Règle stricte** : ne pas commencer une feature de la phase N+1 tant que toutes les features de la phase N ne sont pas terminées ET testées (voir critère de "tâche terminée" dans `CLAUDE.md`).

## Checklists des features

### Feature P0 n°1 : Authentification + utilisateurs + rôles/permissions
- [x] Schéma DB validé (si tables nouvelles/modifiées) _(tables Phase 0 ; aucune migration serveur ; Drift local v2 : `authorUserId` sur la file de mutations)_
- [x] Matrice de permissions CRUD par rôle définie _(docs/permissions.md, validée 2026-09-09 ; cumul par RÔLES, aucune permission à la carte — décision 2026-09-13)_
- [x] Endpoints API implémentés (backend) _(auth : login/refresh/change-password/logout public/me ; users : CRUD, reset, revoke)_
- [x] Validation des entrées (class-validator) en place _(normalisation email/téléphone, MaxLength partout, null refusé en PATCH, rôles non vides)_
- [x] Tests unitaires backend passent (preuve : output réel) _(55 — 2026-09-13)_
- [x] Tests d'intégration backend passent _(89 e2e dont http-hardening et session-hardening (correctifs des audits) — 2026-09-14)_
- [x] UI desktop implémentée _(tableau dense, panneau latéral, rail tablette)_
- [x] UI mobile implémentée _(lignes tactiles, formulaire plein écran)_
- [x] Sync offline gérée si applicable — file de mutations + gestion des rejets _(aucune opération de compte hors-ligne ; file liée à son auteur, quarantaine des mutations d'un autre compte)_
- [x] Revue par subagent `reviewer` _(revue finale 2026-09-14 : aucun bloquant, 5 points corrigés — voir docs/tasks.md)_
- [x] Audit par subagent `security-reviewer` _(audit final 2026-09-14 : **CONFORME** ; 3 mineurs corrigés, testés et contre-éprouvés)_
- [x] Tests manuels effectués par un humain (capture ou description) _(11 captures relues et **validées par MEDMEDBEN le 2026-09-14** ; une version améliorée de l'UI sera fournie plus tard)_
- [ ] `flutter build windows --release` _(poste Windows re-vérifié le 2026-09-14 : `atlstr.h` toujours ABSENT, 2,3 Go libres — installer `Microsoft.VisualStudio.Component.VC.ATL` après libération d'espace)_

### Feature P0 n°2 : Produits + catégories + emplacements + codes-barres
- [x] Schéma DB validé _(aucune table nouvelle ; migration ADDITIVE : séquence `product_internal_barcode_seq` ; Drift local v3 `CatalogEntries`)_
- [x] Matrice de permissions CRUD par rôle définie _(docs/permissions.md § Produits — inchangée)_
- [x] Endpoints API implémentés _(produits, catégories + PATCH, emplacements + PATCH, tarifs/TVA en lecture, `GET /catalog/changes` ; prix par tarif = 501, feature Ventes)_
- [x] Validation des entrées (class-validator) en place _(MaxLength, IsOptionalNotNull, quantités décimales, GTIN à clé contrôlée)_
- [x] Tests unitaires backend passent _(60 — 2026-09-14)_
- [x] Tests d'intégration backend passent _(116 e2e dont 27 catalogue — 2026-09-14)_
- [x] UI desktop implémentée _(tableau dense, panneau latéral)_
- [x] UI mobile implémentée _(lignes tactiles, formulaire plein écran)_
- [x] Sync offline gérée si applicable _(lecture cache-first + delta ; écritures d'administration en ligne uniquement)_
- [x] Revue par subagent `reviewer` _(2026-09-14 : aucun bloquant, 3 points corrigés + suggestions)_
- [x] Audit par subagent `security-reviewer` _(2026-09-14 : NON CONFORME → tout corrigé → contre-audit **CONFORME**)_
- [ ] Tests manuels effectués par un humain _(captures 12 à 17 à relire par MEDMEDBEN — `flutter test test/tools/screen_captures_test.dart --dart-define=CAPTURE_OUT=<dossier>`)_

### Feature P0 n°3 : Stock (quantités, mouvements traçables, projection atomique)
- [x] Schéma DB validé _(migration ADDITIVE `stock_loss_declaration`)_
- [x] Matrice de permissions CRUD par rôle définie _(perte du magasinier EN ATTENTE jusqu'à validation admin — décision 2026-09-14)_
- [x] Endpoints API implémentés _(GET /stock, /stock/movements, GET|POST /stock/losses, validate, reject)_
- [x] Validation des entrées (class-validator) en place
- [x] Tests unitaires backend passent _(62 — 2026-09-15)_
- [x] Tests d'intégration backend passent _(141 e2e — 2026-09-15)_
- [x] UI desktop implémentée
- [x] UI mobile implémentée _(+ onglet « Plus » au-delà de 4 destinations)_
- [x] Sync offline gérée si applicable _(handler MANUAL = même règle qu'en ligne ; déclaration hors-ligne dans l'app : après N6b)_
- [x] Revue par subagent `reviewer` _(2026-09-15 : 2 bloquants + 4 points corrigés)_
- [x] Audit par subagent `security-reviewer` _(2026-09-15 : NON CONFORME → 1 important + 3 mineurs corrigés)_
- [ ] Tests manuels effectués par un humain _(captures 18 à 20 à relire par MEDMEDBEN)_

### Feature P0 n°4 : Ventes (tarifs, TVA/ticket/facture PDF, caisse, dettes clients)
- [x] Schéma DB validé _(migration ADDITIVE `sale_ticket_seq` ; pas de réservation de stock en P0 — décision 2026-09-15)_
- [x] Matrice de permissions CRUD par rôle définie _(prix/tarif/plafond : admin seul ; annulation : admin ; paiement : espèces)_
- [x] Endpoints API implémentés _(prix par tarif, caisse + rapport Z, ventes, facture FA-AAAA-NNNNNN, PDF, annulation, clients, règlements)_
- [x] Validation des entrées (class-validator) en place _(montants bornés, total annoncé vérifié, id idempotents)_
- [x] Tests unitaires backend passent _(72 — 2026-09-15)_
- [x] Tests d'intégration backend passent _(184 e2e — 2026-09-15)_
- [x] UI desktop implémentée
- [x] UI mobile implémentée
- [ ] Sync offline gérée si applicable _(ventes hors-ligne = feature P0 #12, après N6b)_
- [x] Revue par subagent `reviewer` _(2026-09-15 : PAS OK → corrigé ; contre-revue PAS OK (date de facture) → corrigé)_
- [x] Audit par subagent `security-reviewer` _(2026-09-15 : corrigé commit 12b890a ; contre-audit **CONFORME**, 4 mineurs corrigés)_
- [ ] Tests manuels effectués par un humain _(captures 21 à 23 + PDF ticket/facture à relire par MEDMEDBEN)_

## Checklist par feature (à copier dans tasks.md pour chaque feature)

```
### Feature : <nom>
- [ ] Schéma DB validé (si tables nouvelles/modifiées)
- [ ] Matrice de permissions CRUD par rôle définie
- [ ] Endpoints API implémentés (backend, dev A)
- [ ] Validation des entrées (class-validator) en place
- [ ] Tests unitaires backend passent (preuve : output réel)
- [ ] Tests d'intégration backend passent
- [ ] UI desktop implémentée (dev B)
- [ ] UI mobile implémentée (dev B)
- [ ] Sync offline gérée si applicable (dev B) — file de mutations + gestion des rejets
- [ ] Revue par subagent `reviewer`
- [ ] Audit par subagent `security-reviewer`
- [ ] Tests manuels effectués par un humain (capture ou description)
```

## Matrice de permissions CRUD — à produire en Phase 0 (3 rôles)

`docs/spec-fonctionnelle.md` définit les accès à un niveau général. La matrice **action par action** doit être produite et validée par l'utilisateur avant de coder les guards, pour CHAQUE entité (Produit, Client, Fournisseur, Vente, Achat, Réception, Transfert, Inventaire, Utilisateur, Paiement...).

Exemple de format :

| Action | Admin | Vendeur/Caissier | Magasinier |
|---|---|---|---|
| Créer un produit | ✅ | ❌ | ❌ |
| Modifier un produit | ✅ | ❌ | ❌ |
| Désactiver un produit | ✅ | ❌ | ❌ |
| Consulter un produit | ✅ | ✅ | ✅ |
| Créer une vente | ✅ | ✅ | ❌ |
| Ajuster le stock (inventaire) | ✅ | ❌ | ✅ (soumis à validation admin) |
| Valider un ajustement d'inventaire | ✅ | ❌ | ❌ |
| Réceptionner un achat | ✅ | ❌ | ✅ |

**Règle** : cette matrice est une décision humaine explicite, documentée dans `docs/context.md`. Ne jamais laisser Claude Code deviner qui a le droit de supprimer/valider quoi.

## Offline — répartition des données par rôle

| Rôle | Données locales prioritaires |
|---|---|
| Magasinier | Stock dépôt, emplacements, transferts assignés, réceptions en attente, inventaires en cours |
| Vendeur/Caissier | Catalogue produits, stock magasin, panier en cours, clients récents, ventes du jour |
| Admin | Accès majoritairement online ; localement : ce qui est utile à la validation |

Sync : premier lancement = téléchargement initial du sous-ensemble du rôle ; ensuite delta sync uniquement. Images jamais préchargées en masse. Opérations hors-ligne = file de mutations soumise au contrat de sync (`docs/context.md`).
