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
- [ ] Contrat OpenAPI complet pour tous les endpoints P0 (forme uniquement)
- [ ] Auth JWT (login, refresh révocable via table `RefreshToken`, guards par rôle) fonctionnel
- [ ] **Socle du contrat de sync** : UUID client, table de mutations, endpoint idempotent, validation serveur avec rejet (voir `docs/context.md`)
- [ ] Structure Flutter de base (navigation desktop/mobile, thème, client Dio configuré sur le contrat, base Drift + file de mutations)
- [x] `docker-compose.dev.yml` local (PostgreSQL + Redis + MinIO) _(2026-09-09 — démarré et vérifié)_
- [ ] **Matrice de permissions CRUD** des entités P0 validée par l'utilisateur

### Liste EXHAUSTIVE des tables de la Phase 0 (noms canoniques)

```
Auth / Users
  User, Role, Permission, RefreshToken

Catalogue
  Product, Category, Location
  (Product.barcode = unique ; génération interne via séquence si absent)

Stock
  Stock (projection), StockMovement (source de vérité)

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
