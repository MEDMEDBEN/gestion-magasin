# Spécification fonctionnelle — Logiciel de gestion Magasin + Dépôt (matériel électrique)

> **SOURCE DE VÉRITÉ FONCTIONNELLE.** Ce document consolide le cahier fonctionnel détaillé. En cas de contradiction avec tout autre fichier (fichiers racine archivés inclus), **c'est ce document qui prime**. Les règles techniques non négociables sont dans `CLAUDE.md` ; le contrat de synchronisation offline est dans `docs/context.md` ; l'ordre des features et la liste des tables sont dans `docs/plan.md`.

---

## 1. Périmètre

Logiciel de gestion pour **1 magasin + 1 dépôt unique**, avec une petite équipe.

Produits : câbles, LED, lampes, lustres/luminaires, prises, interrupteurs, disjoncteurs et accessoires électriques.

Objectifs :
- une seule source de vérité pour les données ;
- synchroniser le stock magasin/dépôt ;
- supprimer la double saisie papier ;
- gérer ventes, achats, clients, fournisseurs, dettes, réceptions, transferts et inventaires ;
- permettre les opérations terrain sur mobile (y compris hors-ligne) ;
- fournir planning, notifications, statistiques et traçabilité.

**Hors périmètre (ne pas développer par défaut) :** multi-dépôts, multi-magasins, multi-sociétés, ML, IA, LLM, chatbot, agent autonome, OCR obligatoire, recherche visuelle obligatoire, e-commerce obligatoire. L'architecture peut rester extensible, mais le produit doit rester adapté à **1 magasin + 1 dépôt + petite équipe**.

---

## 2. Rôles (figés — 3 rôles)

### Admin
Accès complet : utilisateurs, permissions, produits, stock, ventes, achats, clients, fournisseurs, inventaires, transferts, rapports, planning, notifications, paramètres et audit. Valide les opérations sensibles (ajustements d'inventaire, changements de prix/permission).

### Vendeur / Caissier
Créer les ventes ; rechercher/scanner les produits ; consulter le stock ; gérer les clients ; enregistrer les paiements ; gérer les ventes à crédit (selon permission) ; demander un produit au dépôt ; suivre ses demandes ; recevoir les notifications. **Ne peut pas modifier librement le stock.**

### Magasinier / Saisie dépôt
Gérer le stock dépôt ; rechercher/scanner ; gérer les emplacements ; réceptionner les achats (y compris réceptions partielles) ; préparer les demandes magasin ; effectuer les transferts ; faire les inventaires et comptages planifiés ; signaler les problèmes.

**Un membre peut cumuler des fonctions : l'admin lui attribue plusieurs rôles** (décision 2026-09-13 — pas de permission accordée individuellement, voir `docs/permissions.md`). Les permissions sont contrôlées **côté UI ET côté backend** (le backend fait autorité).

---

## 2bis. Comptes, connexion & première synchronisation

### Création des comptes
- **Pas d'inscription publique.** L'**admin crée** chaque utilisateur (nom, identifiant email/téléphone, rôle, permissions).
- Première connexion : mot de passe temporaire fourni par l'admin → **changement obligatoire** à la première connexion.
- L'admin peut désactiver/réactiver un compte, réinitialiser le mot de passe, et **révoquer les sessions** (téléphone volé, départ).

### Connexion & session
- Login obligatoire : identifiant (email/téléphone) + mot de passe (argon2).
- **Session persistante** : access token 15 min + **refresh token longue durée (90 jours, glissant)** stocké chiffré (`flutter_secure_storage`). L'utilisateur se connecte **une seule fois** ; l'access token est renouvelé silencieusement tant qu'il utilise l'app → il ne ressaisit jamais son mot de passe.
- Re-login requis uniquement si : refresh expiré, session révoquée, compte désactivé, ou déconnexion volontaire. Refresh **révocable** via la table `RefreshToken`.
- Optionnel : verrou **PIN / biométrie** à l'ouverture de l'app (confort + sécurité), sans re-login serveur.
- Après login, le serveur renvoie le rôle → l'app affiche **la vue propre au rôle** et déclenche la synchronisation.

### Première synchronisation puis mises à jour
1. Login → tokens.
2. **Sync initiale** : téléchargement du **sous-ensemble du rôle** dans la base locale (Drift), borné (catalogue complet, historique 30 jours, images en lazy) — voir bornes offline dans `docs/context.md`.
3. **Delta sync** à chaque ouverture/reconnexion : uniquement ce qui a changé depuis le dernier curseur.
4. **Hors-ligne** : lecture du local ; les opérations créées vont dans la **file de mutations**.
5. **Reconnexion** : push des mutations (validées/rejetées par le serveur) + pull du delta.

> Distinction clé : **données de référence** (téléchargées pour la lecture hors-ligne, rafraîchies par delta) ≠ **opérations créées hors-ligne** (file de mutations poussée à la reconnexion). Voir le contrat de synchronisation dans `docs/context.md`.

---

## 3. Modules

```
Dashboard · Ventes · Caisse · Produits · Stock · Clients · Fournisseurs · Achats
Réceptions · Transferts · Inventaires · Planning · Notifications
Communication · Rapports · Utilisateurs/Permissions · Traçabilité · Paramètres
```

---

## 4. Produits

Champs : ID (UUID) ; référence/SKU ; code-barres ; nom ; catégorie ; sous-catégorie (si besoin) ; marque ; unité ; prix d'achat ; prix de vente ; TVA (si utilisée) ; image (facultative) ; seuil minimum ; stock de sécurité (si utilisé) ; fournisseur principal ; actif/inactif.

Les **catégories** servent à organiser, rechercher, filtrer et analyser les produits (hiérarchie via `parent_id`).

> Coût pour la marge = **dernier prix d'achat réceptionné** (décision figée, voir `CLAUDE.md`). Les prix unitaires historiques restent sur `PurchaseLine`/`ReceptionLine`.

**Unité & quantités** : chaque produit a une `unit` (pièce, mètre, rouleau…). Les **quantités sont décimales** (ex : 12,5 m de câble) — voir règle 10 de `CLAUDE.md`.

**TVA** : taux de TVA par produit (peut être 0). **Tarifs** : le prix de vente vient d'un **tarif** (détail / gros…), pas d'un champ unique — voir §8bis.

---

## 5. Emplacements dépôt

Structure : `Zone → Rayon → Étagère → Position`. Exemple : `Zone A → Rayon 02 → Étagère 04 → Position 03`. Le magasinier doit retrouver rapidement un produit.

---

## 6. Stock

Le système distingue : stock **magasin**, stock **dépôt**, stock **en transit** (et quantités **réservé** / **disponible**).

Exemple : `LED 12W — Magasin 20 · Dépôt 50 · Transit 10 · Total 80`. Pour une vente, seule la quantité **disponible au magasin** est utilisable.

**Règle fondamentale (voir `CLAUDE.md`) :** toute modification de stock provient d'une **opération** (vente, réception, transfert, retour, ajustement d'inventaire, perte/casse). Le mouvement (`StockMovement`, delta additif) est la **source de vérité** ; `Stock.quantity` est une projection recalculée dans la même transaction. **Aucune modification silencieuse.**

**Réservation** : à définir précisément en Phase 0 — par défaut, la quantité est **réservée à la validation de la vente** (pas au simple ajout au panier), et libérée si la vente est annulée.

---

## 7. Mouvements de stock

Chaque mouvement contient : produit ; quantité (delta) ; type ; source ; destination ; utilisateur ; date ; opération liée ; commentaire éventuel.

Types : `RECEPTION, VENTE, RETOUR_CLIENT, RETOUR_FOURNISSEUR, TRANSFERT_SORTIE, TRANSFERT_ENTREE, AJUSTEMENT_INVENTAIRE, PERTE_CASSE`.

---

## 8. Ventes

Workflow : `Produit → Client → Panier → Paiement → Validation`. Ajout produit par recherche, référence, code-barres ou scan mobile.

Panier (par ligne) : produit ; quantité ; prix unitaire ; remise (si autorisée) ; total ; disponibilité.

Une vente **validée** (dans une seule transaction) : enregistre la vente + ses lignes ; crée les mouvements de stock (magasin −qté) ; met à jour la projection ; met à jour le CA/statistiques ; crée/met à jour la dette client si vente à crédit ; écrit l'audit.

> La vente peut être créée **hors-ligne** (voir §22 et le contrat de sync) : le stock est re-validé au moment du sync, la dette est calculée côté serveur.

---

## 8bis. Tarifs, TVA / facturation, Caisse

### Tarifs (détail / gros)
Le prix de vente d'un produit dépend d'un **tarif** (`PriceTier` : ex. `DETAIL`, `GROS`). `ProductPrice` porte le prix par (produit × tarif). Chaque client a un **tarif par défaut** (particulier → détail, électricien pro → gros). À la vente, la ligne prend le prix du tarif du client ; une remise ponctuelle reste possible selon permission. **Le prix appliqué est figé sur la `SaleLine`.**

### TVA, ticket et facture
- Chaque produit a un **taux de TVA** (peut être 0).
- Une vente est de type **`TICKET`** (par défaut) ou **`FACTURE`**.
- La vente stocke **HT / TVA / TTC** (calcul déterministe à partir des lignes).
- Une **facture** reçoit un **numéro légal séquentiel et continu**, attribué **côté serveur en ligne** (jamais côté client, jamais hors-ligne). Une vente faite hors-ligne est un **ticket** ; sa transformation en facture (attribution du numéro) se fait à la reconnexion. Voir règle 11 de `CLAUDE.md`.
- **Formats de numérotation** (par année, séquence réinitialisée chaque année) : facture `FAC-AAAA-NNNNN`, devis `DEV-AAAA-NNNNN`, bon de commande `BC-AAAA-NNNNN`, transfert `TRF-AAAA-NNNNN` (ex : `FAC-2026-00001`). Le compteur de facture est sans trou (transaction serveur) ; les autres compteurs sont séquentiels par type.

### Caisse (clôture quotidienne)
- Le caissier **ouvre une session** de caisse avec un **fond de caisse** (`CashSession`).
- Les **encaissements espèces** se rattachent à la session ouverte (`CashMovement` : `VENTE_ESPECES`, `ENTREE`, `SORTIE`, `PRELEVEMENT`).
- La **clôture** compte le réel vs l'attendu et enregistre l'**écart** → **rapport Z** de fin de journée.
- Règle : pas d'encaissement espèces hors session ouverte (voir règle 12 de `CLAUDE.md`).

---

## 8ter. Codes-barres & étiquettes

### Codes-barres
- À la saisie d'un produit : s'il a **déjà un code-barres** (fabricant / EAN), on le **scanne ou le saisit** et on le stocke tel quel.
- Sinon, le logiciel **génère automatiquement un code-barres interne unique** (compatible impression : EAN-13 à préfixe interne ou Code128), issu d'une **séquence garantissant l'absence de doublon**. Contrainte d'unicité en base sur `Product.barcode` (voir règle 15 de `CLAUDE.md`).
- Un code-barres n'est jamais partagé par deux produits.

### Étiquettes
- Générer des **étiquettes imprimables** : nom du produit, prix, image du code-barres.
- Sortie : **planche A4** (grille, imprimante bureautique) et/ou **imprimante thermique** (rouleau).
- Sélection multiple → générer une planche pour une liste de produits (ex : tout un réassort). À coller sur les produits exposés.

---

## 8quater. Devis

- Le vendeur crée un **devis** : client, lignes (produit, quantité, prix selon tarif, remise éventuelle), TVA, date de validité.
- Statuts : `BROUILLON → ENVOYE → ACCEPTE → CONVERTI` (+ `REFUSE`, `EXPIRE`).
- Un devis **accepté** se **convertit en vente** en un clic (reprend les lignes).
- Un devis **ne touche jamais le stock** (aucun mouvement) — seule la vente crée les mouvements.
- Sortie **PDF** (voir §8quinquies).

---

## 8quinquies. Génération de documents (PDF / Excel)

Le logiciel génère des fichiers selon la fonctionnalité (nécessaire pour un usage réel) :

- **PDF** : ticket de caisse, facture, devis, bon de livraison / bon de transfert, bon de commande fournisseur, rapports.
- **Excel / CSV** : exports d'historique et de listes — ventes, stock, mouvements, inventaires, achats, réceptions, clients, fournisseurs, dettes.
- Génération **côté serveur** (rendu déterministe et identique pour tous). Les factures peuvent être **archivées** (MinIO) ; les autres documents sont générés à la demande.
- **Mobile** : partage / impression directe du PDF (ticket, devis).
- **Import** (P1) : produits, clients, fournisseurs, stock initial via Excel/CSV.
- Une seule bibliothèque par besoin (PDF, Excel, code-barres) — voir `CONVENTIONS.md`.

---

## 9. Dettes clients + paiements

`Reste = Total − Somme des paiements`. Exemple : Total 100 000 · Payé 60 000 · Reste 40 000 (dette).

- **Échéance** : date prévue de paiement.
- **Retard** : `date actuelle − échéance` si dépassée et non réglée.

La fiche client affiche : dette restante, échéance, retard, paiements effectués. Les paiements ultérieurs (`CustomerPayment`) sont enregistrés et réduisent la dette. La dette est **toujours recalculée**, jamais stockée en dur.

---

## 10. Clients

Nom ; téléphone ; adresse (si besoin) ; email (si besoin) ; historique des ventes ; total acheté ; montant payé ; montant restant ; échéances ; retards.

---

## 11. Fournisseurs

Nom ; téléphone ; email ; adresse ; contacts ; produits fournis ; commandes ; réceptions ; total acheté ; montant payé ; montant restant dû.

Indicateurs : total acheté, nombre de commandes, livraisons à temps, retards, réceptions partielles, évolution des prix d'achat.

---

## 12. Dettes fournisseurs + paiements

Indépendante de l'historique des achats. Exemple : Achat 500 000 · Payé 300 000 · Reste dû 200 000.

Afficher : total, payé, reste, échéance/retard si applicable, paiements (`SupplierPayment`). L'historique répond à « qu'avons-nous acheté ? » ; la dette à « combien devons-nous encore ? ».

---

## 13. Achats

Commande fournisseur : fournisseur ; date ; produits ; quantités ; prix d'achat ; total ; paiement ; échéance ; statut.

Statuts : `BROUILLON → COMMANDEE → CONFIRMEE → PARTIELLEMENT_RECUE → RECUE` (+ `ANNULEE`).

---

## 14. Réceptions (dont partielles)

Une réception est **séparée** de la commande (une commande peut avoir plusieurs réceptions).

Exemple : Commande 100 → Réception 70 (reste 30, statut `PARTIELLEMENT_RECUE`, stock +70) → Réception 30 (70+30=100, statut `RECUE`). Le stock augmente **uniquement** des quantités réellement réceptionnées.

---

## 15. Réception mobile au dépôt

Workflow : `Commande → Vérification → Scan si nécessaire → Quantité reçue → Validation`. Après validation : stock dépôt augmenté ; réception enregistrée ; reste recalculé ; statut mis à jour ; mouvement créé ; audit enregistré. Fonctionne hors-ligne (file de mutations).

---

## 16. Demande magasin → dépôt

Le vendeur demande (ex : `LED 12W × 20`, avec priorité et commentaire). Le magasinier reçoit la demande.

La demande devient un **transfert** avec statut et historique — pas un simple message.

---

## 17. Transferts dépôt → magasin

Un transfert contient : produit ; quantité demandée ; quantité préparée ; quantité transférée ; quantité reçue ; demandeur ; préparateur ; dates ; statut.

Statuts : `DEMANDEE → ACCEPTEE → EN_PREPARATION → PREPAREE → EN_TRANSIT → RECUE` (+ `REFUSEE`, `ANNULEE`). Préparation partielle gérée par les quantités de `TransferLine`.

Cas d'erreur à prévoir : stock insuffisant, produit introuvable, quantité différente, produit endommagé, refus, annulation. Le produit n'est disponible au magasin **qu'après réception** ; il est `EN_TRANSIT` entre-temps.

---

## 18. Notifications

Ciblées selon le rôle. Types : stock faible ; rupture ; nouvelle demande dépôt ; demande prête ; transfert ; transfert reçu ; commande confirmée ; réception ; réception partielle ; retard fournisseur ; échéance/dette client proche ou en retard ; dette fournisseur à payer ; inventaire à faire ; écart détecté ; tâche du jour ; tâche en retard.

Chaque notification : type ; priorité ; destinataire ; date ; statut lu/non lu ; lien vers l'opération.

---

## 19. Réapprovisionnement

Règle simple : `Stock disponible <= seuil minimum` → produit à réapprovisionner. Le système propose une quantité (ex : stock 8, seuil 20 → recommandé 50). L'utilisateur peut modifier avant de commander. Niveau avancé (P2) : historique des ventes, vitesse, saisonnalité, délai fournisseur, stock de sécurité/transit, commandes ouvertes.

---

## 20. Produits demandés / dormants

**Demandés** : les plus vendus ; les plus demandés au dépôt ; souvent demandés mais indisponibles (demande commerciale malgré rupture).

**Dormants** : sans mouvement depuis une durée configurable (ex : 120 jours) → éviter un nouvel achat, promotion, transfert, analyse.

---

## 21. Dashboard

### Desktop
Résumé, pas une base de données. KPI : CA du jour ; CA période ; nombre de ventes ; achats/dépenses ; bénéfice/marge ; stock faible ; ruptures ; demandes dépôt ; réceptions ; dettes clients ; dettes fournisseurs. Sections : produits les plus vendus ; alertes ; activités importantes ; transferts ; commandes à recevoir. Graphiques : évolution des ventes ; CA par période ; ventes par catégorie ; répartition du stock ; produits les plus vendus. **Ne pas surcharger.**

### Mobile (léger)
Uniquement : urgent ; important aujourd'hui ; actions fréquentes.
- **Vendeur** : bouton Nouvelle vente + Scanner, ventes du jour + CA, demandes dépôt, alertes, mes tâches.
- **Magasinier** : à faire (demandes/réceptions/inventaire), Scanner, demandes à préparer, réceptions.
- **Admin** : alertes, tâches, CA du jour, opérations importantes.

### CA et part du CA
CA = chiffre d'affaires. Part du CA = contribution d'un produit/catégorie au CA total (ex : Câbles 200 000 / total 1 000 000 = 20 %).

---

## 22. Inventaire

Comparer `théorique ↔ physique`. `Écart = physique − théorique`. État de ligne : `CONFORME` (écart 0) / `ECART` (≠ 0). Un ajustement doit être **autorisé (admin) et traçable** (mouvement `AJUSTEMENT_INVENTAIRE`).

### Inventaire tournant
Compter régulièrement une partie du stock (ex : semaine 1 → Zone A, etc.). Chaque inventaire : date ; zone/produits ; responsable ; état ; écarts ; date de réalisation.

---

## 23. Planning hebdomadaire

L'admin crée un planning de saisie/révision par semaine. Une tâche (`PlanningTask`) : membre ; type ; zone/produits ; date ; échéance ; statut ; commentaire ; résultat.

Statuts : `A_FAIRE → EN_COURS → TERMINEE` (+ `EN_RETARD` si échéance dépassée). L'admin voit : tâches terminées, en retard, écarts, travail par membre.

---

## 24. Traçabilité / audit

Journal d'audit des actions importantes : utilisateur ; action ; type d'objet ; ID objet ; ancienne valeur ; nouvelle valeur ; date/heure. Actions : `CREATE, UPDATE, CANCEL, VALIDATE, ADJUST`.

Actions sensibles à auditer : modification de prix ; ajustement stock ; validation vente ; réception ; transfert ; annulation ; changement de permission. **Les ventes normales restent dans Ventes/Statistiques — elles ne polluent pas la vue d'audit des modifications membres.**

---

## 25. Communication interne (P1)

Communication simple magasin ↔ dépôt et admin ↔ membres (question, information, consigne, signalement). **Une opération métier structurée ne doit jamais être remplacée par un message** (ex : demander 20 LED = une vraie demande dépôt).

---

## 26. Signalement de problème (P1)

Titre ; catégorie ; description ; priorité ; photo (facultative) ; auteur ; date ; statut. Catégories : stock incorrect, produit manquant, produit endommagé, problème informatique, problème matériel, autre. Statuts : `OUVERT → EN_COURS → RESOLU → FERME`.

---

## 27. Scanner mobile

Rechercher un produit ; voir stock magasin/dépôt ; ajouter à une vente ; inventaire ; réception ; préparation transfert. Après scan : produit, stock magasin, stock dépôt, emplacement, prix, actions autorisées.

---

## 28. Fonctions P2 (secondaires)

- **Commande fournisseur préparée automatiquement** (sans IA) : le système prépare une commande (produit, quantité recommandée, fournisseur), l'utilisateur vérifie et valide. Message fournisseur à modèle fixe (`Bonjour, nous souhaitons commander [QUANTITE] unités de [PRODUIT]. Merci de confirmer.`), canal email ou WhatsApp si intégration.
- **Contact clients ciblé** : pour un nouveau produit, identifier les clients ayant acheté une catégorie similaire ; message par modèle, validé avant envoi.
- **OCR factures / recherche photo** : uniquement si pertinent, jamais source de vérité, toujours corrigeable avant validation.

---

## 29. Mobile vs Desktop

**Desktop** : administration, rapports, analyse, configuration, grandes listes, gestion détaillée, caisse.
**Mobile** : vente, scan, consultation rapide, réception, préparation, inventaire, transfert, demandes dépôt, notifications, planning.

**Ne pas faire une copie miniature du Desktop.** UX mobile : une action principale par écran ; secondaire dans « Voir plus » ; grands boutons tactiles ; texte lisible ; peu de cartes/couleurs ; pas de tableaux desktop ; recherche rapide ; feedback immédiat ; confirmations pour actions sensibles. Navigation type : `Accueil | Ventes | Stock | Tâches | Plus` (adaptée par rôle).

---

## 30. UI — identité électrique

**80 % logiciel professionnel + 20 % identité électrique.** Thème sombre (bleu nuit/noir), surfaces légèrement plus claires, coins arrondis modérés, bordures fines, accent **cyan/bleu électrique**, très peu de glow. Éléments possibles : petit disjoncteur dans la sidebar, interrupteur décoratif, câble discret, micro-effets lumineux, icônes électriques. Éviter : néons excessifs, glow partout, câbles partout, interface gaming, animations permanentes.

Palette : fond bleu/noir très sombre ; surface bleu nuit ; accent cyan/bleu électrique ; succès vert ; avertissement jaune/orange ; erreur rouge.

**États UI obligatoires sur chaque écran important** : `Loading`, `Empty`, `Error`, `Success`, `Offline`, `Sync en attente` (`✓ Synchronisé` / `⟳ En attente de synchronisation`).

---

## 31. Modèle de données (noms canoniques)

```
Auth/Users : User, Role, Permission, RefreshToken
Catalogue  : Product, Category, Location
Stock      : Stock (projection), StockMovement (source de vérité)
Ventes     : Sale, SaleLine, Customer, CustomerPayment
Tarifs/TVA : PriceTier, ProductPrice, TaxRate, InvoiceCounter
Caisse     : CashSession, CashMovement
Devis      : Quote, QuoteLine
Achats     : Supplier, SupplierPayment, PurchaseOrder, PurchaseLine, Reception, ReceptionLine
Transferts : Transfer, TransferLine
Inventaire : Inventory, InventoryLine
Planning   : PlanningTask
Système    : Notification, AuditLog, SyncMutation
P1         : Conversation, Message, Problem
```

Relations essentielles :
```
User      → Sales, Transfers, Inventories, PlanningTasks, Problems, AuditLogs
Product   → Stock, StockMovements, SaleLines, PurchaseLines, TransferLines, InventoryLines
Customer  → Sales, CustomerPayments
Supplier  → PurchaseOrders, SupplierPayments
PurchaseOrder → PurchaseLines, Receptions
Reception → ReceptionLines
Transfer  → TransferLines
Inventory → InventoryLines
```

Champs clés :
- **Montants** : entiers (centimes de DA).
- **IDs** des entités créables hors-ligne : UUID générés côté client.
- `Stock(product_id, location_id, quantity, reserved_quantity, in_transit_quantity)`
- `StockMovement(id, product_id, source_location, destination_location, quantity, type, operation_id, user_id, date)`
- `PurchaseLine(purchase_id, product_id, ordered_quantity, received_quantity, unit_price)`
- `ReceptionLine(reception_id, product_id, received_quantity, unit_price)`
- `TransferLine(transfer_id, product_id, requested_quantity, prepared_quantity, received_quantity)`
- `InventoryLine(inventory_id, product_id, theoretical_quantity, counted_quantity, difference, state)`
- `CustomerPayment(id, customer_id, sale_id?, amount, date, method)` · `SupplierPayment(id, supplier_id, purchase_id?, amount, date, method)`

---

## 32. Architecture technique

**Frontend** : Flutter, Riverpod, go_router, Dio, Freezed, Drift (offline).
**Backend** : NestJS, Prisma, PostgreSQL, Redis (si nécessaire), MinIO, Docker.
**API** : REST + OpenAPI ; WebSocket (Socket.IO) pour le temps réel.

Couches : `Presentation → Application/Use Cases → Domain/Business Rules → Infrastructure → DB/Services`. Le domaine ne dépend pas directement de Flutter/PostgreSQL/fournisseur externe. Les règles critiques sont **côté backend**.

---

## 33. Offline et synchronisation

Périmètre : **large dès le départ, ventes incluses.** Le détail complet (UUID client, file de mutations, idempotence, validation/rejet serveur, anti-stock-négatif, UX de réconciliation) est le **Contrat de synchronisation** dans `docs/context.md` — **à respecter à la lettre**. Ne jamais afficher comme définitive une opération non synchronisée.

---

## 34. Règles métier critiques (rappel — détail dans `CLAUDE.md`)

- Vente validée → stock magasin diminué, dans une transaction atomique.
- Réception : 100 commandés, 70 reçus → stock +70 seulement.
- Transfert : dépôt → transit → magasin.
- Inventaire : `physique − théorique = écart` ; ajustement autorisé + traçable.
- Dette = montant dû − paiements enregistrés (toujours recalculée).
- Permissions : UI + backend (backend fait autorité).
- Éviter les stocks négatifs (sauf backorder explicitement autorisé).
- Pas de suppression physique d'une opération validée : annulation / correction / opération inverse.

---

## 35. Priorités et scénarios

Ordre des features P0 → P3 : voir `docs/plan.md`. Priorités absolues : **fiabilité des données → simplicité → rapidité → traçabilité.** Ne pas ajouter une fonctionnalité uniquement parce qu'elle est techniquement intéressante.

### Scénario de validation principal (doit réussir)
```
Achat → Commande fournisseur → Réception dépôt 70/100 → Stock dépôt +70
→ Commande = Partiellement reçue → Demande magasin 20 → Préparation dépôt
→ Transfert → Réception magasin → Stock magasin +20 → Vente 3 → Stock magasin −3
→ Inventaire → Écart éventuel → Validation ajustement → Audit des actions
```

### Scénario dettes
- Client : Vente 100 000, Payé 60 000, Dette 40 000, Échéance 15/09 → paiement 20 000 → Reste 20 000.
- Fournisseur : Achat 500 000, Payé 300 000, Dette 200 000 → paiement → Dette 0.

---

## 36. Règle finale

Le logiciel doit être **simple dans son périmètre mais sérieux dans sa logique** : 1 magasin + 1 dépôt + petite équipe + gestion complète + stock fiable + dettes clients/fournisseurs + communication simple + planning hebdomadaire + notifications + traçabilité + application mobile. Le système reste fiable même sans aucune fonction IA.
