# Diagnostic complet — ERP Magasin/Dépôt matériel électrique
*Analyse pré-implémentation · avant lancement de l'agent Claude Code*

---

## Verdict global

Le dossier est **solide et bien au-dessus de la moyenne** : architecture cohérente, méthodologie de relais à deux devs bien pensée, règles métier non négociables clairement posées, subagents pertinents, sécurité bien répartie code/infra. La gouvernance de projet (CLAUDE.md + tasks.md + plan.md) est excellente.

**Mais il n'est pas prêt à lancer tel quel.** Il reste des incohérences entre tes documents et des trous dans le schéma qui feront dérailler l'agent dès la Phase 0. Ce sont des corrections de documents, pas de code — comptez 1 à 2 h de mise au propre. Une fois faites, tu peux lancer l'agent en confiance.

**Décision : ne lance pas encore. Corrige les 5 points 🔴 ci-dessous, puis tu es prêt.**

---

## Ce qui est déjà très bien (à garder tel quel)

- **Méthodologie contrat-d'abord + tranches verticales + relais async** via `tasks.md` : c'est la bonne approche pour éviter les trous fonctionnels. Le protocole de début/fin de session est excellent.
- **Règles métier non négociables** dans CLAUDE.md : mouvements de stock additifs (delta), historique immuable, permissions serveur, réceptions partielles séparées de la commande. C'est exactement ce qui rend un ERP fiable.
- **Séparation sécurité code (Claude) / sécurité infra VPS (toi)** : claire et réaliste.
- **RefreshToken en table révocable** (DEPLOYMENT.md) : bon réflexe, souvent oublié.
- **Subagents** (reviewer, security-reviewer, tester, db-migrator) : bien cadrés, avec la bonne règle « jamais de feu vert par défaut ».
- **Infra** : Postgres/Redis non exposés, Traefik + Let's Encrypt auto, backup pg_dump documenté. Propre.
- **settings.json** : permissions Claude Code raisonnables (deny rm -rf / force-push / prisma reset).

---

## 🔴 BLOQUANTS — à corriger AVANT de lancer l'agent

### 1. Tes deux documents fonctionnels se contredisent — et l'agent n'en lira qu'un seul

C'est le problème le plus important.

- `Plan_Agent.md` (racine) est **identique** à `docs/spec-fonctionnelle.md` (même taille, 30014 octets). C'est le document que CLAUDE.md désigne comme « référence à lire intégralement ».
- `Cahier_Fonctionnel_Magasin_Depot_Complet.md` est à la **racine `ERP_Elec/`, en dehors du repo `gestion-magasin-config/`**. Claude Code travaille dans `gestion-magasin-config/` (c'est là que sont CLAUDE.md et `.claude/`). **Donc l'agent ne lira JAMAIS le Cahier.**

Or le Cahier contient des choses **absentes** de la spec de référence, et qui sont marquées P0 chez lui :
- **Dettes clients + paiements** (`CustomerPayment`) — P0
- **Dettes fournisseurs + paiements** (`SupplierPayment`) — P0
- **Planning hebdomadaire** (`PlanningTask`) — P0
- Le périmètre **restreint et décisif** : « 1 magasin + 1 dépôt », et surtout la section **« Hors périmètre »** (multi-dépôts, ML, IA, LLM, chatbot, OCR/e-commerce non obligatoires).

À l'inverse, la spec de référence (`Plan_Agent`) parle d'architecture « prête pour OCR, vision, ML, e-commerce », de rôle « Responsable » et « Lecture seule », etc.

**Conséquence si tu ne corriges pas :** l'agent va suivre `spec-fonctionnelle.md`, ignorer les dettes et le planning (pourtant P0 chez toi), et potentiellement sur-architecturer pour l'IA/e-commerce que tu as explicitement exclus.

**Correction :**
- Décide quel document fait foi. Je recommande de **fusionner** : prends le périmètre restreint + les dettes + le planning du Cahier, et intègre-les dans `docs/spec-fonctionnelle.md`. Ajoute explicitement la section « Hors périmètre » du Cahier dans la spec.
- Supprime la duplication : garde **une seule** source (`docs/spec-fonctionnelle.md`), et mets les deux fichiers racine hors du repo ou en archive, pour qu'il n'y ait aucune ambiguïté.

### 2. Le nombre de rôles n'est pas le même dans 3 documents

- `spec-fonctionnelle.md` / `Plan_Agent` : **5 rôles** — Admin, Responsable, Vendeur/caissier, Magasinier, Lecture seule.
- `Cahier_Fonctionnel` : **2-3 rôles** — Admin, Vendeur/Caissier, Magasinier (pas de Responsable ni de Lecture seule).
- `plan.md` (matrice de permissions) : **5 rôles** (Admin, Responsable, Vendeur, Magasinier, Lecture seule).
- `context.md` : **4 rôles** (admin, responsable, vendeur, magasinier).

**Impossible de définir les permissions** (qui est déjà signalé comme « vrai trou » dans plan.md) tant que la liste des rôles n'est pas figée. C'est une décision humaine, à prendre maintenant.

**Correction :** fige la liste exacte des rôles dans un seul endroit (idéalement une enum documentée dans `docs/context.md`), et aligne les 3 documents dessus.

### 3. Le schéma Prisma de la Phase 0 est incomplet par rapport à ton propre P0

La liste d'entités de `plan.md` (Phase 0) est :
> User, Role, Product, Category, Location, Stock, StockMovement, Sale, SaleLine, Purchase, PurchaseLine, Reception, Supplier, Customer, Transfer, InventoryCount, Notification, AuditLog

Il manque des tables qui sont **P0** d'après le Cahier ou nécessaires à la cohérence :

- **`CustomerPayment` / `SupplierPayment`** — sans ces tables, pas de gestion de dettes. Or les dettes sont P0. **Manquant.**
- **`RefreshToken`** — DEPLOYMENT.md dit explicitement « à ajouter au schéma Prisma en Phase 0 », mais la liste de plan.md ne le mentionne pas. **Incohérence entre deux docs.**
- **Tables de lignes** : `ReceptionLine`, `TransferLine`, `InventoryLine` ne sont pas listées (seuls Reception/Transfer/InventoryCount le sont). Sans lignes, pas de réception partielle multi-produits ni de comptage détaillé. **Manquant.**
- **`Permission`** (si tu veux des permissions granulaires plutôt que juste un rôle en dur).
- **`PlanningTask`** (P0 chez le Cahier).

**Correction :** avant la Phase 0, écris la liste **complète et définitive** des tables P0 dans `plan.md`, en y ajoutant au minimum : `CustomerPayment`, `SupplierPayment`, `RefreshToken`, `ReceptionLine`, `TransferLine`, `InventoryLine`. Décide si `PlanningTask` est P0 (Cahier) ou P1.

### 4. La stratégie offline sous-estime un vrai risque : le survente / stock négatif

`context.md` affirme :
> « Tout mouvement de stock est un delta additif → sync sûre **sans logique de résolution de conflit sophistiquée**. »

C'est vrai pour éviter les **écrasements** (lost updates), mais **ça ne protège pas contre le stock négatif**. Exemple : deux appareils vendent hors-ligne la dernière unité d'un produit. Au moment de la sync, les deux deltas (`-1` et `-1`) s'appliquent → stock = `-1`, ce qui **viole ta règle « éviter les stocks négatifs »** (spec section 34). Le modèle additif seul ne résout pas ça.

Il manque donc, explicitement :
- Une **validation serveur au moment de la sync** capable de **rejeter** une mutation en file d'attente (ex : vente qui rendrait le stock négatif), pas seulement de l'appliquer.
- Une **UX de réconciliation** pour une opération hors-ligne rejetée (que voit le vendeur ? annulation ? re-saisie ?). Non conçue aujourd'hui.
- **Idempotence de la sync** : chaque mutation doit porter un identifiant unique généré côté client (`client_mutation_id`), et le serveur doit **dédupliquer** pour qu'un rejeu (reconnexion instable) ne double-applique pas un mouvement. Non spécifié — c'est LE bug classique de l'offline.
- **IDs générés côté client** (UUID, idéalement UUIDv7) pour toutes les entités créables hors-ligne, sinon collision d'auto-increment à la sync. Mentionné vaguement (« identifiants uniques ») mais pas posé comme règle.

**Aussi une ambiguïté de périmètre :** le Cahier classe « Offline avancé » en **P2 (#39)**, alors que CLAUDE.md/context.md en font une fondation. Décide clairement : **qu'est-ce qui marche hors-ligne en P0/P1 ?** (ma reco : en P0, offline = lecture seule + file d'attente pour réception/inventaire au dépôt ; la vente hors-ligne, plus risquée, vient plus tard et avec validation stricte au sync.)

**Correction :** ajoute une section « Contrat de synchronisation » dans `docs/context.md` qui pose : UUID client, `client_mutation_id` + idempotence, validation serveur qui peut rejeter, règle anti-stock-négatif au sync, et la liste précise des opérations autorisées hors-ligne par phase.

### 5. Ambiguïté « source de vérité » du stock : `Stock.quantity` vs somme des `StockMovement`

Ton modèle a **à la fois** une table `Stock(quantity, reserved, in_transit)` (valeur absolue) **et** `StockMovement` (deltas). Si les deux sont modifiables indépendamment, ils **vont diverger** — exactement le problème que le logiciel doit éliminer.

**Correction (décision à figer) :** les **mouvements sont la source de vérité**, et `Stock.quantity` est une **projection** (cache) recalculée **dans la même transaction** que le mouvement. À écrire noir sur blanc dans CLAUDE.md avec la règle : « on n'écrit jamais `Stock.quantity` directement ; on insère un mouvement, et la projection est mise à jour atomiquement (même transaction DB) ».

---

## 🟠 IMPORTANTS — à combler tôt (peuvent se décider en Phase 0)

- **Méthode de coût / marge non décidée.** Le KPI « bénéfice/marge » et « évolution des prix d'achat » exigent une base de coût. `Product.purchase_price` en champ unique et mutable détruit l'historique. Décide : coût = **dernier prix d'achat**, ou **CUMP/PMP** (coût moyen pondéré) ? Les prix unitaires sont bien sur `PurchaseLine`/`ReceptionLine` (bien), mais la **règle de valorisation** manque.
- **L'argent en float = interdit.** Aucune règle ne dit comment stocker les montants. Pose la règle : **montants en entiers (centimes de DA)**, jamais en `float`/`double`, côté DB et côté Dart. Bug financier classique sinon.
- **Machines à états incohérentes pour les transferts.**
  - spec : `Demande → Accepté → En préparation → Expédié → Reçu`
  - Cahier : `Demandée → Acceptée → En préparation → Préparée → En transit → Reçue`
  Fige **une seule** enum de statuts (mêmes noms) avant de coder.
- **Réservation de stock non spécifiée.** `reserved_quantity` existe, mais aucune règle ne dit **quand** on réserve (ajout au panier ? validation ?) ni quand la réservation expire. À décider, sinon comportement flou.
- **Atomicité vente → mouvement → projection.** À écrire explicitement : une vente validée doit créer la vente + ses lignes + les mouvements + la mise à jour de projection **dans une seule transaction** (tout ou rien).
- **Nommage d'entités à harmoniser** : `Purchase` (plan.md) vs `PurchaseOrder` (spec) ; `InventoryCount` (plan.md) vs `Inventory`/`InventoryLine` (spec/Cahier). Choisis un jeu de noms et applique-le partout avant d'écrire le schéma.
- **La matrice de permissions CRUD doit être un livrable de Phase 0.** plan.md la reporte « au démarrage de chaque feature », mais la Phase 0 dit « guards par rôle fonctionnels ». Contradiction : au minimum, la matrice des entités P0 doit exister avant d'écrire les guards. C'est bien flaggé comme trou — juste, avance-la.

---

## 🟡 MINEURS — cosmétique / dette technique légère

- **`version: "3.9"` dans les deux docker-compose est obsolète** (Compose Spec l'ignore et affiche un warning). Supprime la ligne `version:` — ce n'est plus nécessaire.
- **`argon2` (Node natif)** nécessite des dépendances de build dans l'image Docker (Alpine surtout). Prévois-le dans le `backend/Dockerfile`, sinon le build prod cassera. (Alternative : `@node-rs/argon2`, pré-compilé.)
- **MinIO exposé publiquement** sur `storage.tondomaine.com` (port S3 9000) : correct pour servir les images, mais décide **bucket public** vs **URLs présignées**. Pour un catalogue produit, les présignées sont plus propres.
- **CI/CD GitHub Actions** est mentionné (CLAUDE.md/DEPLOYMENT) mais aucun `.github/workflows/` n'existe. Normal à ce stade, juste à ne pas oublier.
- **WebSocket (Socket.IO)** apparaît dans CLAUDE.md mais pas dans le stack des specs fonctionnelles (qui disent REST + OpenAPI). Cohérent (temps réel = P1), juste à noter. Traefik gère l'upgrade WS par défaut, et avec un seul backend pas besoin de sticky sessions.
- **Nom du dossier `gestion-magasin-config`** alors que DEPLOYMENT/CLAUDE décrivent `gestion-magasin/`. Sans importance, mais l'agent créera `backend/` et `app/` **dans** ce dossier — assure-toi que c'est bien là que tu veux la racine du repo Git.

---

## Recommandation : checklist à faire avant de lancer l'agent

Dans l'ordre, tout est de la mise au propre de documents (pas de code) :

1. **Fusionner** Cahier + spec en **une seule** `docs/spec-fonctionnelle.md` faisant foi (y intégrer dettes, paiements, planning, et la section « Hors périmètre »). Sortir les fichiers dupliqués de la racine du repo.
2. **Figer la liste des rôles** (une enum) et aligner tous les docs + faire la matrice de permissions des entités P0.
3. **Compléter la liste des tables P0** dans plan.md : ajouter `CustomerPayment`, `SupplierPayment`, `RefreshToken`, `ReceptionLine`, `TransferLine`, `InventoryLine` (+ décider `PlanningTask`).
4. **Écrire le « Contrat de synchronisation »** dans context.md : UUID client, idempotence (`client_mutation_id`), validation serveur qui peut rejeter, anti-stock-négatif au sync, opérations offline autorisées par phase.
5. **Poser 4 règles non négociables** dans CLAUDE.md : (a) mouvements = source de vérité, `Stock.quantity` = projection recalculée dans la même transaction ; (b) montants en entiers (centimes) ; (c) méthode de valorisation du coût choisie ; (d) une vente = une transaction atomique.
6. **Harmoniser** les noms d'entités et les machines à états (transferts, achats, inventaire).

Une fois ces 6 points faits, ton dossier passe de « très bon brouillon » à « prêt à exécuter ». La Phase 0 (schéma Prisma + contrat OpenAPI + auth) pourra démarrer sans que l'agent ait à deviner quoi que ce soit — et c'est justement le but que tu t'es fixé dans CLAUDE.md.

---

*Rien dans ce dossier n'est « faux » au sens d'une erreur de conception grave. Les problèmes sont des incohérences entre documents et des décisions non encore prises — pas des mauvais choix. Le socle technique (Flutter/NestJS/Postgres/Prisma/Drift) est parfaitement adapté à ce que tu construis.*
