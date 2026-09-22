# CLAUDE.md — Logiciel de gestion magasin/dépôt (matériel électrique)

Ce fichier est lu automatiquement par Claude Code à chaque session. Il définit les règles non négociables du projet.

## Vision du projet
Logiciel de gestion centralisé pour un magasin de matériel électrique + dépôt. Cœur du produit : la connexion fiable magasin ↔ dépôt (stock, transferts, ventes, achats). Périmètre : **1 magasin + 1 dépôt + petite équipe**. Voir « Hors périmètre » dans `docs/spec-fonctionnelle.md`.

## Documents de référence — ordre de priorité en cas de doute
1. **`docs/spec-fonctionnelle.md`** — SOURCE DE VÉRITÉ FONCTIONNELLE. Décrit tous les rôles, modules, workflows, règles métier, dettes, planning, le modèle de données complet et la stratégie offline. **À lire intégralement avant la Phase 0.** En cas de contradiction avec tout autre fichier, c'est ce fichier qui prime.
2. **Ce fichier (`CLAUDE.md`)** — règles techniques non négociables et méthodologie.
   - **`CONVENTIONS.md`** (racine) — conventions de code obligatoires (structure module NestJS / feature Flutter, DTO, format d'erreurs, pagination, money/decimal). À respecter par tout dev/agent pour que le code reste homogène d'une session à l'autre.
   - **`docs/permissions.md`** — matrice de permissions CRUD par rôle (à valider puis refléter exactement dans les guards).
3. **`docs/context.md`** — décisions d'architecture + **Contrat de synchronisation offline** (à respecter à la lettre).
4. **`docs/plan.md`** — ordre des features (P0 → P3) et liste exhaustive des tables de la Phase 0.
5. **`docs/tasks.md`** — état d'avancement / relais entre devs. **Toujours le lire en premier en début de session.**
6. **`docs/DEPLOYMENT.md`** — infra, VPS, secrets.

> Note : les fichiers `Cahier_Fonctionnel_*.md` et `Projet_Gestion_*.md` à la racine du dossier parent sont l'origine historique de la spec (le Cahier = fonctionnel détaillé, le Projet = idée globale). Ils sont **archivés** : ne pas s'y référer pour coder. Tout leur contenu utile a été consolidé dans `docs/spec-fonctionnelle.md`.

## Rôles (figés — 3 rôles)
- **Admin** : accès complet + validation des opérations sensibles + gestion utilisateurs/permissions/paramètres/audit.
- **Vendeur / Caissier** : ventes, recherche/scan produit, clients, paiements, ventes à crédit (selon permission), demandes au dépôt, notifications. Ne peut pas modifier librement le stock.
- **Magasinier** : stock dépôt, emplacements, réceptions (y compris partielles), préparation des demandes, transferts, inventaires, comptages planifiés, signalement de problèmes.

Un membre peut **cumuler** des fonctions : l'admin lui attribue **plusieurs rôles** (décision MEDMEDBEN du 2026-09-13 — pas de permission accordée individuellement). La matrice CRUD détaillée par entité est à produire en Phase 0 (voir `docs/plan.md`).

## Stack technique
- **Frontend (desktop + mobile, un seul code)** : Flutter, Riverpod (state), go_router (navigation), Dio (HTTP), Freezed (modèles), Drift (SQLite local / offline)
- **Backend** : NestJS (TypeScript), Prisma (ORM), REST + OpenAPI, WebSocket (Socket.IO) pour le temps réel
- **Base de données** : PostgreSQL (source de vérité serveur), Redis (cache/queues), MinIO (fichiers/images, S3-compatible)
- **Auth** : JWT (access 15min + refresh révocable en table), argon2 pour les mots de passe
- **Hébergement** : VPS + Docker, CI/CD via GitHub Actions

## Structure des dossiers
```
backend/
├── src/
│   ├── auth/ users/ roles/ products/ inventory/ stock/ locations/
│   ├── transfers/ sales/ customers/ purchases/ suppliers/ receptions/
│   ├── payments/ planning/ notifications/ reports/ problems/ messaging/
│   ├── automation/ audit/ sync/ storage/
│   └── common/         ← guards, decorators, pipes partagés
├── prisma/schema.prisma
├── test/
└── Dockerfile

app/  (Flutter, desktop + mobile)
├── lib/
│   ├── core/           ← logique métier partagée (100% commune)
│   ├── data/           ← modèles, API client, DB locale (Drift), moteur de sync
│   ├── features/       ← une feature = un dossier (auth, sales, stock, transfers...)
│   └── ui/
│       ├── desktop/    ← layouts spécifiques desktop
│       └── mobile/     ← layouts spécifiques mobile
└── test/

infra/                  ← déploiement (voir docs/DEPLOYMENT.md)
├── docker-compose.yml       (production, VPS)
├── docker-compose.dev.yml   (dev local : PostgreSQL/Redis/MinIO)
└── .env.example
```

## Méthodologie de développement — RÈGLE CENTRALE

**Approche : Contrat d'abord, puis tranches verticales par feature, en relais asynchrone (les deux devs ne codent JAMAIS en même temps — ils se relaient à des heures différentes).**

1. **Phase 0 (fondation, une seule fois)** : schéma Prisma complet pour P0 (liste exhaustive dans `docs/plan.md`) + contrat OpenAPI complet + auth de base + **contrat de synchronisation offline** (`docs/context.md`). Ne JAMAIS commencer une feature avant que la Phase 0 soit validée par les deux devs.
2. **Par feature ensuite** : chaque feature (ex: "Ventes") est développée de bout en bout (DB → API → sécurité → UI → sync offline → tests) avant de passer à la suivante.
3. **Le relais se fait ENTRE features, jamais au milieu d'une feature.**
4. **Ordre des features** : suivre strictement `P0 → P1 → P2 → P3` tel que défini dans `docs/plan.md`.
5. **Sécurité** : chaque feature doit être auditée par le subagent `security-reviewer` avant d'être considérée terminée.

## Protocole de relais (travail asynchrone, à des heures différentes)

**Au début de CHAQUE session, dans cet ordre :**
1. `git pull`
2. Lire `docs/tasks.md` en entier — ne jamais commencer à coder sans ça
3. Reprendre exactement à la "prochaine étape" indiquée, pas ailleurs

**Avant de pousser et fermer la session :**
1. S'assurer que le code compile / passe les tests (preuve réelle)
2. Mettre à jour `docs/tasks.md` : ce qui a été fait, état exact du code, prochaine étape **précise** (fichier + ce qu'il reste à faire)
3. `git push`
4. Utiliser `/update-dev-docs` pour automatiser cette mise à jour

## Règles métier NON NÉGOCIABLES

Ces règles priment sur toute considération de simplicité ou de rapidité. Le subagent `reviewer` doit les vérifier à chaque revue.

1. **Permissions vérifiées côté serveur systématiquement**, jamais seulement côté UI. Chaque endpoint a un guard de rôle explicite.
2. **Le stock est un journal d'événements, pas un compteur.** La table `StockMovement` (deltas additifs) est la **source de vérité** du stock. La table `Stock.quantity` est une **projection** (cache) recalculée **dans la même transaction DB** que l'insertion du mouvement. On n'écrit JAMAIS `Stock.quantity` directement — on insère un mouvement et la projection suit atomiquement. Ne jamais écraser une quantité par une valeur absolue.
3. **Atomicité des opérations composées.** Une vente validée = (Sale + SaleLines + StockMovements + mise à jour projection + dette client éventuelle) dans **une seule transaction** : tout ou rien. Idem réception, transfert, ajustement d'inventaire.
4. **L'argent se stocke en ENTIERS (centimes de DA).** Jamais de `float`/`double` pour un montant, ni en DB (Prisma `Int`/`BigInt`), ni côté Dart. Formatage en dinars uniquement à l'affichage.
5. **Méthode de coût = dernier prix d'achat.** Le coût d'un produit pour le calcul de marge/bénéfice = le dernier prix unitaire réceptionné. Marge = prix de vente − dernier prix d'achat. (Les prix unitaires historiques restent stockés sur `PurchaseLine`/`ReceptionLine`.)
6. **Réceptions fournisseurs** : gérer les réceptions partielles séparément de la commande (une commande peut avoir plusieurs réceptions). Le stock augmente uniquement des quantités réellement réceptionnées.
7. **Historique immuable** : toute opération (vente, transfert, réception, ajustement) crée une entrée d'historique / mouvement. Pas de suppression physique d'une opération validée — préférer annulation / correction / opération inverse.
8. **Synchronisation offline sûre** : voir le **Contrat de synchronisation** dans `docs/context.md`. Points non négociables : IDs générés côté client (UUID), chaque mutation porte un `client_mutation_id` unique, le endpoint de sync est **idempotent**, et le serveur **valide et peut REJETER** une mutation (ex : vente qui rendrait le stock négatif). Une opération non synchronisée ne doit jamais être affichée comme définitive.
9. **Anti-stock-négatif** : au moment du sync (et en ligne), une opération qui rendrait le stock disponible négatif est **rejetée** par défaut, sauf produit explicitement marqué « backorder autorisé ».
10. **Quantités = décimales.** Les quantités (stock, lignes de vente/achat/transfert/inventaire, mouvements) sont des **décimaux** (Prisma `Decimal`, ex : `Decimal(14,3)`), pas des entiers — certains produits se vendent au mètre. Chaque produit porte une `unit` (pièce, mètre, rouleau…). Ne jamais typer une quantité en `Int`.
11. **Numérotation des factures = séquentielle, sans trou, générée serveur uniquement.** Une facture officielle (avec TVA) reçoit un numéro légal séquentiel et continu, attribué **côté serveur dans une transaction**, jamais côté client, jamais hors-ligne. Une vente créée hors-ligne est un **ticket** ; sa conversion en facture (attribution du numéro) se fait **en ligne**. La TVA est un taux par produit ; la vente stocke HT/TVA/TTC.
12. **Caisse : une vente en espèces est rattachée à une session de caisse ouverte.** Le caissier ouvre une session (fond de caisse), les encaissements espèces s'y rattachent, la clôture compte le réel vs l'attendu et produit l'écart (rapport Z). Pas d'encaissement espèces hors session ouverte.
13. **Tarifs multiples.** Le prix de vente vient d'un **tarif** (ex : détail / gros), pas d'un champ unique sur le produit. La ligne de vente prend le tarif du client (ou le tarif par défaut). Le prix appliqué est **figé sur la `SaleLine`** au moment de la vente. **Les tarifs sont gérés par l'admin** ; au moment de la vente, le vendeur (comme l'admin) peut **modifier le prix unitaire d'une ligne** (décision MEDMEDBEN du 2026-09-22), **jamais sous le dernier prix d'achat** (sans coût connu : jamais sous le plus bas de ses tarifs — provisoire, à revoir plus tard ; ni coût ni tarif : pas de vente tant que l'admin n'a pas fixé un prix — validé par MEDMEDBEN le 2026-09-22) — vérifié par le serveur. La ligne garde le prix du tarif ET le prix appliqué ; une vente à prix modifié est tracée pour l'admin. Le **coût d'achat est visible des trois rôles** (décision MEDMEDBEN du 2026-09-22, remplace le secret du 2026-09-14) : c'est le plancher que le vendeur doit connaître, hors ligne compris. La remise (`sale.discount`) reste réservée à l'admin.
14. **Comptes & session.** Pas d'inscription publique : l'**admin crée** les utilisateurs ; **changement de mot de passe obligatoire** à la première connexion. **Session persistante** via refresh token long (90 j, glissant) révocable, stocké en `flutter_secure_storage` ; re-login seulement si refresh expiré/révoqué/compte désactivé. La numérotation de facture et l'attribution des sessions restent **serveur**. Voir `docs/spec-fonctionnelle.md` §2bis.
15. **Codes-barres uniques & génération de documents.** `Product.barcode` est **unique** (contrainte DB). À la saisie : code fabricant scanné s'il existe, sinon **génération interne garantie unique** (séquence, jamais de doublon). La génération de PDF, d'exports Excel/CSV et d'images de codes-barres passe par les **utilitaires uniques** définis dans `CONVENTIONS.md` (une seule bibliothèque par besoin). Un devis (`Quote`) ne crée **aucun mouvement de stock**.

## Critère de "tâche terminée" — OBLIGATOIRE
Ne jamais marquer une tâche comme terminée sans preuve concrète :
- Résultat de build réel (pas "ça devrait compiler")
- Résultat de tests réels (pas "les tests devraient passer")
- Pour une feature UI : capture d'écran ou description de ce qui a été vérifié manuellement

## Git — branche unique, pas de branches parallèles
Une seule branche de travail (`develop`), utilisée à tour de rôle. `main` reste stable, merge de `develop` uniquement après validation.

## Commandes utiles
```bash
# Backend
cd backend && npm run start:dev       # lancer en dev
cd backend && npm run test            # tests unitaires
cd backend && npm run test:e2e        # tests d'intégration
cd backend && npx prisma migrate dev  # migration DB

# Frontend
cd app && flutter run -d windows      # lancer desktop
cd app && flutter run                 # lancer mobile (device connecté)
cd app && flutter test                # tests
cd app && flutter build windows       # build desktop
cd app && flutter build apk           # build mobile
```

## Mise à jour de la checklist EN CONTINU
Cocher chaque case de la checklist de feature (`docs/plan.md`) et mettre à jour `docs/tasks.md` **au fur et à mesure**, pas seulement en fin de session. Après chaque sous-étape terminée (un endpoint, un écran, un test), mettre à jour immédiatement.

## Périmètre de sécurité — répartition claire
- **Sécurité applicative (code)** — responsabilité de Claude Code (backend ET frontend) : guards NestJS, validation des entrées, hash argon2, `flutter_secure_storage` pour les tokens, aucun secret en dur. Couvert par `security-reviewer`.
- **Sécurité infrastructure / VPS (opérationnel)** — responsabilité de l'utilisateur : durcissement serveur, firewall, secrets de prod, rotation des clés, sauvegardes, monitoring. Claude Code prépare les fichiers Docker/infra mais ne les exécute jamais en prod.

## Design système
Un design (desktop et mobile) sera fourni en cours de route par l'utilisateur — pas complet, mais suffisant pour en extraire un design système cohérent. Dès réception :
1. Extraire le design système du design fourni (ne pas improviser une palette différente).
2. Appliquer ce design système à tous les écrans non couverts, de façon cohérente.
3. Respecter la direction artistique de `docs/spec-fonctionnelle.md` (80% logiciel professionnel + 20% identité électrique, thème sombre, accent cyan/bleu électrique) tant que le design fourni ne la contredit pas.

## Subagents disponibles
- `reviewer` — relit le code avant chaque commit (qualité, cohérence, règles non négociables).
- `security-reviewer` — audit sécurité obligatoire à la fin de chaque feature.
- `tester` — écrit et lance les tests (priorité stock + argent).
- `db-migrator` — gère les migrations Prisma en sécurité (jamais de migration destructive sans confirmation explicite).

## Plugins installés (contexte pour Claude Code)
- `ponytail` — privilégie toujours la solution la plus simple (YAGNI).
- `graphify` — graphe de connaissance du code.
- `code-review` — revue automatisée multi-spécialiste sur les PR.
- `frontend-design` — qualité des interfaces Flutter.
