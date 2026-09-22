# État d'avancement

> Les deux devs travaillent à des heures différentes, jamais en simultané — ce fichier EST le relais.
> Règle stricte : `git pull` + lire ce fichier en entier AVANT de coder. Le mettre à jour + `git push` avant de fermer.
> **Signer par NOM** (MEDMEDBEN / Ratybox), plus par rôle : on se signait tous les deux « Dev A ».

## ✅ CORRECTIONS DE LA REVUE GÉNÉRALE — 2026-09-17 · **MEDMEDBEN** (à lire avant de coder)
Bilan de départ : `docs/revue-generale-2026-09-16.md`. Règles durcies ajoutées dans `CONVENTIONS.md` (« Invariants &
anti-récidive », 6 règles). Tout ce qui suit est poussé sur `develop`, **non mergé sur `main`** (re-revue d'abord).

**Bloquants — corrigés de façon GÉNÉRALISÉE**
1. **Caisse jamais négative** : `CashSessionsService.withdraw` = SEUL chemin de sortie d'espèces (annulation de vente,
   paiement fournisseur, contre-passation d'un règlement) → `CASH_INSUFFICIENT`. `deposit` pour les entrées hors vente.
2. **Idempotence de toutes les mutations d'argent** : `common/idempotency.ts` (`clientMutationId` OBLIGATOIRE, renvoi
   identique = même résultat, autre contenu = 409, envois simultanés relus) sur ventes, règlements clients, paiements
   fournisseurs, ouverture ET clôture de caisse, contre-passations. Migration additive `money_idempotency_and_reversals`.
   App : `core/mutation_keys.dart` garde la clé PAR INTENTION jusqu'au succès (fin du double paiement au réessai).
3. **Catalogue local** : synchro lancée par la coquille à chaque connexion + à l'entrée en Vente ; état affiché si vide.

**Stabilité**
- **Guard unique** : `FreshAccessGuard` GLOBAL sur toute écriture authentifiée (plus aucun `@UseGuards` à oublier) ;
  lecture sensible : `@RequireFreshAccess()` (comptes).
- Annulation/retour possibles sur produit désactivé (seules les SORTIES sont refusées) ; **unité figée** après mouvement.
- Tri en liste blanche + fin des N+1 (ventes, clients, fournisseurs, commandes).
- **Lint à zéro** (`.gitattributes` eol=lf, `argsIgnorePattern '^_'`) ; **e2e en un seul passage** sur une **base de test
  dédiée** `<base>_test` (créée, migrée et seedée par `test/global-setup.ts`, timeout 30 s) — la base de dev n'est plus touchée.
- Facture : numéro et date calculés sur le MÊME instant (plus de `FA-2026` daté 2027).
- **Tests de concurrence** (règle 6) : règlements simultanés, clôture pendant des ventes, changement d'année de
  numérotation, mutations offline concurrentes sur le même stock (`test/concurrency.e2e-spec.ts`).

**Décisions MEDMEDBEN 2026-09-16 — implémentées (serveur + app)**
- **Liste des caisses (ADMIN)** : `GET /cash-sessions` (filtres statut/caissier/période) ; app : onglet « Caisses » → rapport Z.
- **Échéance** : `dueDate` OBLIGATOIRE sur toute vente à crédit (aujourd'hui ou plus tard, interdite si soldée) ;
  `overdueAmount` sur la fiche client ; app : calendrier à l'encaissement à crédit, badge « En retard ».
- **Annulation de paiement par CONTRE-PASSATION** (jamais suppression) : `POST /payments/customer/:id/reverse` et
  `/payments/supplier/:id/reverse` (ADMIN, motif obligatoire, une seule fois, rejouable) + historiques
  `GET /customers/:id/payments`, `GET /suppliers/:id/payments` ; app : dialogue d'historique commun avec « Contre-passer ».

**Preuves (2026-09-17)** : backend `eslint` 0 erreur · **81** unit · **232** e2e (17 suites, un seul passage) ;
app `flutter analyze` propre · **+203 ~27**. Protections contre-éprouvées (garde retiré → test en échec) : caisse,
relecture concurrente, clé gardée, synchro coquille/Vente, guard global, produit désactivé, unité figée.

**Re-revue du 2026-09-20** — `reviewer` : **MERGE POSSIBLE** (preuves relancées par lui : 81 unit, 232 e2e en un
passage, app +203 ~27). Corrigé dans la foulée : `docs/permissions.md` commité (contre-passation, caisses, échéance) ;
« en retard » compté à partir du LENDEMAIN de l'échéance (une vente due aujourd'hui n'est plus en retard) ; toutes les
écritures de caisse passent par `CashSessionsService` (`withdraw`/`deposit`/`recordCashSale`) ; montants des messages
d'erreur en DA et non en centimes ; `npm run lint:check` (vérifie sans modifier, utilisable en CI) ; tests ajoutés :
échéance du jour, deux contre-passations simultanées, clôture pendant une contre-passation. Preuve : **81** unit ·
**235** e2e. `security-reviewer` (relancé le 2026-09-20) : **MERGE POSSIBLE**, aucun problème critique ni important, 5 mineurs
dont 4 corrigés dans la foulée : tri en liste blanche sur les historiques de paiements, en-têtes HTTP (`nosniff`,
`DENY`, `no-referrer`, `x-powered-by` retiré) et corps JSON borné à 128 ko, liste UNIQUE des routes d'argent
(`backend/test/money-routes.ts`) partagée entre l'aide de test et le test « sans clé → 400 » (une future route ne peut
plus y échapper), exemption des transitions d'état documentée dans `CONVENTIONS.md`. Non fait, tracé : passer
`SupplierPayment.clientMutationId` et `CashSession.openMutationId` en NOT NULL (migration additive, après stabilisation
des données) ; `helmet` si `/docs` est un jour exposé. Point assumé : une contre-passation passe par la caisse OUVERTE
de l'admin, pas par la session d'origine du caissier (décision du 2026-09-16, écrite dans `docs/permissions.md`).
Preuve finale : backend **81** unit · **235** e2e (un passage) · lint 0 ; app analyze propre · **+203 ~27**.
**`develop` est prêt à être mergé sur `main`** (en attente du feu vert de MEDMEDBEN).

### P0 #7 RÉCEPTIONS — CODE LIVRÉ (2026-09-20 · **MEDMEDBEN**)
Le stub 501 des réceptions est remplacé par la vraie feature (`backend/src/receptions/`, `app/lib/features/receptions/`).
- **La dette fournisseur naît à la RÉCEPTION** : `ReceptionLine.lineTotalTtc` fige le TTC (TVA prise sur la ligne de
  COMMANDE quand la réception y est rattachée, sinon celle du produit) et `SuppliersService.debt` vaut désormais
  **reprise + marchandise reçue − paiements**. Une reprise révisée ne peut plus descendre sous `payé − reçu`.
- **Surlivraison refusée** : jamais plus que le reste à recevoir d'une ligne, y compris en CUMULANT deux lignes du même
  bon. Contre-épreuve : garde retirée → le test échoue.
- **Même verrou que l'annulation** : `PurchaseOrdersService.lockOrder` (le `SELECT … FOR UPDATE`) est devenu le point
  d'entrée UNIQUE, partagé par modification, confirmation, annulation et réception. Contre-épreuve : verrou remplacé par
  une simple lecture → le test « annulation et réception simultanées » laisse commande annulée ET stock entré.
- Réceptions partielles : une commande en accepte plusieurs, son statut suit le cumul (PARTIELLEMENT_RECUE puis RECUE) ;
  une commande soldée, annulée, brouillon ou seulement envoyée n'en accepte aucune.
- Le stock n'entre que par `StockLedgerService` (règle 2), `Product.lastPurchasePriceHt` suit le dernier prix reçu
  (règle 5), tout est audité, et la réception porte un `clientMutationId` obligatoire (elle est dans `MONEY_ROUTES`).
- Numéro `BR-AAAA-NNNNN` par le générateur unique (`DocumentType.RECEPTION`, migration additive).
- **App** : action « Réceptionner la marchandise » sur une commande engagée (ADMIN|MAGASINIER + `reception.create`),
  reste à recevoir pré-rempli, emplacement obligatoire, surlivraison bloquée avant l'envoi, clé d'idempotence stable
  par formulaire ; « Réceptions enregistrées » liste les bons d'une commande.
- `src/generated/` est sorti du périmètre eslint : `prisma generate` rendait le lint rouge sans raison.

**Audits P0 #7** — `reviewer` **PAS OK** (1 bloquant) · `security-reviewer` **NON CONFORME** (2 importants) → corrigés :
- **Bloquant : le dialogue « Réceptions enregistrées » affichait son propre code.** Trois interpolations Dart étaient
  échappées ; Dart compile, `flutter analyze` ne dit rien, et aucun test n'ouvrait cet écran. Corrigé, et un test
  ouvre désormais réellement le dialogue et vérifie que le montant est FORMATÉ (il échoue si le code réapparaît).
- **Important : le prix d'achat venait du bon de réception.** Un magasinier pouvait donc réécrire le prix confirmé par
  l'admin, donc la dette fournisseur ET le coût de marge (règle 5). Désormais, sur une ligne rattachée à une commande,
  le prix (comme la TVA) vient de la COMMANDE ; celui du bon est ignoré. Test : bon à 1 centime sur une commande à
  1 200,00 → dette et coût à 1 200,00.
- **Important : la réception hors commande était ouverte au magasinier.** Sans commande, c'est un achat complet (stock,
  dette, coût) sans engagement d'un admin. Réservée à l'ADMIN, décision écrite dans `docs/permissions.md`.
- `Reception.totalTtc` figé (migration additive avec backfill) : la dette fournisseur se somme par `groupBy` au lieu de
  charger toutes les lignes de tous les bons de la page.
- Un produit présent sur deux lignes d'un même bon : le coût retenu est celui de la DERNIÈRE ligne du bon, plus celui
  que l'ordre de verrouillage désignait au hasard.
- Clé d'idempotence complétée (ligne de commande et note comprises), motif décimal des quantités inscrit au contrat
  OpenAPI (400 au lieu d'un 422 tardif), lecture des réceptions commentée, clé d'intention libérée sur 409 `CONFLICT`
  côté app (sans quoi chaque nouvel essai rejouait le même conflit).

**Tracé, non fait** (à traiter avant la mise en service) :
- ~~Commande partiellement reçue sans reliquat à venir~~ → **fait le 2026-09-20** (statut `CLOTUREE`, voir plus bas).
- `ReceptionLine.note` (colonne du schéma Phase 0) n'est alimentée par rien.
- `$transaction` sans `timeout` explicite avec jusqu'à 200 lignes : plafond Prisma par défaut à 5 s, comme partout
  ailleurs dans le projet.
- La réception est **en ligne uniquement** : `MutationType.RECEPTION` n'a pas de handler de synchronisation.

**Preuve (2026-09-20, après corrections)** : backend `lint:check` 0 · **81** unit · **246** e2e (18 suites, un seul
passage) ; app `flutter analyze` propre · **+209 ~27**.

### 🧹 REMISE À NIVEAU AVANT DE CONTINUER (2026-09-20 · **MEDMEDBEN**)
Demande : « je ne veux plus d'erreurs de base ». Quatre points traités.

**1. Commande partiellement reçue sans reliquat à venir** (trou trouvé la veille) :
nouveau statut `CLOTUREE` + `POST /purchase-orders/:id/close` (ADMIN, motif obligatoire, même verrou
`lockOrder` que la réception, audité). Refusé sur une commande sans réception (elle s'annule) et sur une
commande déjà soldée ; plus aucune réception après clôture ; ce qui est reçu reste reçu (règle 7).
Côté app : action « Clôturer le reliquat » (ADMIN), motif obligatoire. Preuve : 2 e2e + 1 test widget.

**2. Le projet est déployable.**
- `backend/Dockerfile` (deux étages, utilisateur non-root, `migrate deploy` au démarrage) et
  `.dockerignore` (ni `.env`, ni tests, ni `.git`). **Image construite ET démarrée** : `/api/health` → 200,
  route protégée → 401, en-têtes de sécurité présents, migrations appliquées.
- **Défaut trouvé au passage : l'application ne démarrait pas en production.** Le client Prisma généré
  s'importait avec l'extension `.ts` explicite ; le JS compilé gardait `require('./internal/class.ts')`.
  Corrigé à la source : `importFileExtension = ""` sur le générateur Prisma — sans extension, `tsc`,
  `ts-node` et `jest` résolvent tous le `.ts` à la compilation et le `.js` à l'exécution. (Premier essai,
  `rewriteRelativeImportExtensions`, réglait le build mais cassait `ts-node` : seed et tests d'intégration.)
  Personne n'avait jamais exécuté le build compilé.
- `prisma` et `dotenv` passent en dépendances de PRODUCTION (la CLI sert au démarrage du conteneur) ;
  `prisma7.config.ts` renommé `prisma.config.ts` (nom que la CLI attend).
- **NestJS 10 → 11** + `overrides` npm (`multer`, `deepmerge-ts`, `mysql2`) : `npm audit` passe de
  **21 vulnérabilités (8 hautes)** à **4 modérées**, toutes dans l'arbre de `minio`. Elles ne sont PAS
  corrigeables : les versions corrigées de `decode-uri-component` et `stream-json` sont ESM pur et
  casseraient minio à l'exécution (projet CommonJS). À revoir à la prochaine version de `minio`.
- **MinIO n'est plus exposé** : route Traefik supprimée (le backend sert les fichiers lui-même, aucune URL
  pré-signée). Service `minio-init` : crée le bucket et un **compte de service limité à ce seul bucket** ;
  le compte root vit dans `.env.minio-root`, chargé par MinIO seul — le backend ne l'a jamais.
- **Signature Android** : la release n'est plus signée avec la clé de debug. `key.properties` (jamais
  versionné, `*.jks` ignorés) + `isMinifyEnabled`. ⚠️ **Non prouvé sur ce poste** : le build APK échoue sur
  un NDK Android corrompu (dossier vide dans le SDK) — problème de machine, à refaire après réinstallation.

**3. Relecture humaine : de quoi relire enfin.** L'outil de capture couvre maintenant **31 écrans**
(réception desktop et mobile, clôture du reliquat, liste des caisses ajoutés) et **tourne vert**. Deux vrais
défauts trouvés en le remettant en marche :
- `CatalogSyncController.refresh()` écrivait l'état d'un provider **détruit** (déconnexion ou fermeture
  pendant une synchro) → garde `ref.mounted`.
- Les droits ADMIN du jeu de test ne reflétaient plus `ROLE_PERMISSIONS` : l'admin de capture ne voyait ni
  « Vente » ni les réceptions. Complétés.
  Captures écrites dans le dossier passé à `--dart-define=CAPTURE_OUT=…`.

**4. `main` créée et alignée sur `develop`** (commit `7693fbc`), après correction de tous les points
bloquants des audits. À noter : `main` n'avait **jamais existé** dans le dépôt — `develop` reste la branche
de travail ET la branche par défaut du dépôt distant.

**Corrections de l'audit sécurité du 2026-09-20** : le bloc `environment:` du service `minio` **vidait**
`MINIO_ROOT_USER`/`MINIO_ROOT_PASSWORD` (`${...}` s'interpole depuis `.env`, jamais depuis un `env_file`, et
`environment` prime) — MinIO aurait démarré sans identifiants et le provisionnement aurait échoué. Bloc
supprimé, rendu vérifié. Aussi : rotation du secret du compte de service prise en compte, `minio-init` attendu
en `service_completed_successfully` (le backend n'a pas le droit de créer le bucket), action d'audit `CLOSE`
distincte de `CANCEL` (migration additive), droits ADMIN du jeu de captures alignés sur les 39 permissions.

⚠️ **Incident machine du 2026-09-21** : les conteneurs ET les volumes Docker de `gestion-magasin`
(`infra-postgres-1`, `infra-minio-1`) avaient disparu — base de développement locale perdue (données de seed
uniquement, aucune perte réelle). Recréés depuis `infra/docker-compose.dev.yml` puis migrés et re-seedés.
Les conteneurs de l'autre projet de la machine tournent sur d'autres ports (5433, 9002-9003) : aucun conflit.

**Corrections de la revue du 2026-09-21** (elle avait conclu **PAS OK**, 2 bloquants) :
- **Bloquant : sur un serveur neuf, personne n'aurait pu se connecter.** Le seed — seule voie d'existence du
  premier compte (règle 14, aucune inscription publique) — utilisait `ts-node` et `tsconfig.seed.json`, tous
  deux absents de l'image de production. Le script est passé en `src/seed.ts`, donc **compilé** avec le reste,
  et le conteneur enchaîne désormais migrations → seed → démarrage. **Prouvé sur une base VIERGE** : le
  conteneur démarre, migre, seede, et l'admin se connecte (HTTP 200 sur `/api/auth/login`).
- **Bloquant : `.env.minio-root` n'était pas ignoré par Git** — `.env` ne couvre que ce nom exact. Corrigé par
  `.env.*` + `!.env.*.example`, vérifié avec `git check-ignore`.
- **Le durcissement MinIO n'avait jamais été exercé** : la preuve Docker tournait avec le compte ROOT de la
  base de développement. Refait avec un compte de service **réellement limité au bucket** : le backend démarre,
  et `StorageService` ne tente plus de créer le bucket (droit qu'il n'a pas) — il exige qu'il existe et, si ce
  n'est pas le cas, refuse de démarrer avec un message exploitable au lieu de « Valid and authorized
  credentials required ».
- `minio-init` ne reçoit plus tout `.env` (JWT, mot de passe PostgreSQL, `DATABASE_URL`…) : moindre privilège.
- `postgres` a une sonde de santé et le backend l'attend : le `migrate deploy` du démarrage ne peut plus tomber
  au tout premier lancement.
- Ménage : chaîne `mc admin` ramenée à une ligne (les deux branches de repli ne s'appliquaient jamais), copie
  morte de `src/generated` retirée de l'image (4,2 Mo), `tsconfig.build.json` et deux commentaires purgés du
  nom `prisma7.config.ts`, `CLOTUREE` ajouté à la machine à états (`docs/plan.md`, `schema.prisma`), clôture
  inscrite dans `docs/permissions.md`, dette obsolète barrée ci-dessus, magasin de clés en PKCS12 des deux
  côtés, et `npm audit` annoncé à sa vraie valeur (**4** modérées, pas 3).

**Preuve (2026-09-21)** : backend `lint:check` 0 · **81** unit · **248** e2e (18 suites, un seul passage) ·
image Docker reconstruite, démarrée sur une **base vierge** avec un compte MinIO **restreint**, premier admin
connecté ; app `flutter analyze` propre · **+210 ~31** · **31 captures** produites.

### 🚧 P0 #12 RACCORDEMENT HORS-LIGNE — EN COURS (2026-09-21 · **MEDMEDBEN**)

**État de départ constaté** : le moteur de sync existe (serveur `POST /api/sync` + file Drift + `SyncEngine`),
mais **rien dans l'app ne met en file ni ne déclenche la synchronisation** — toute écriture passe en ligne.
Un seul handler serveur (`MANUAL`, perte/casse), et même lui n'est appelé par aucun écran.

**Principe retenu (chemin hybride)** : chaque écriture tente d'abord EN LIGNE ; si le réseau manque
(`ApiException.isOffline`), elle part dans la file **avec la MÊME clé que l'intention en ligne**. Raison : si la
requête en ligne est arrivée au serveur mais que la réponse s'est perdue, la mutation mise en file sera
RECONNUE (même `clientMutationId` que l'entité) au lieu d'être appliquée une seconde fois. Chaque handler de
sync appelle donc le MÊME cœur que la route en ligne, y compris son contrôle « déjà enregistrée ».

**Tranches (chacune testée, contre-éprouvée et poussée avant la suivante)** :
- [x] **A — Socle app** (livrée, auditée) — voir le détail juste après la liste.
- [x] **B — Vente hors-ligne** (livrée, auditée) — détail après la liste.
- [x] **C — Caisse hors-ligne** (livrée, auditée) — détail après la liste.
- [x] **D — Réception hors-ligne** (livrée, auditée) — détail après la liste.
- [ ] **E — Transferts, inventaire (comptage), règlements clients** hors-ligne.
- Restent EN LIGNE, volontairement : facturation (numéro légal), validation d'inventaire et de pertes (geste
  admin), commandes et paiements fournisseurs, fiches produits/clients/fournisseurs, planning, comptes —
  gestes de bureau, faits au poste fixe, où un « dernier écrivain gagne » masquerait des conflits.

**Tranche A — livrée (2026-09-21)**
- **Serveur (N6b)** : le lot `POST /api/sync` porte `authorUserId` (obligatoire, 400 sinon). Différent du porteur
  du token → tout le lot `NON_TRAITEE` / `SYNC_AUTHOR_MISMATCH`, rien traité ni mémorisé, trace `warn` sans
  contenu. Décision écrite dans `docs/context.md` (2026-09-21).
- **App** : `SyncCoordinator` (`data/sync/sync_coordinator.dart`, écouté par `AdaptiveShell`) pousse la file à la
  connexion, au retour du réseau et toutes les 30 s ; le cycle d'un compte ne s'affiche jamais au suivant.
  `SyncEngine` : un cycle en cours PAR AUTEUR. `writeOnlineOrQueue` (`core/offline_write.dart`) : essai en ligne,
  sinon mise en file sous la MÊME clé et le MÊME corps ; l'auteur est lu AVANT l'attente réseau et rien n'est mis
  en file si le compte a changé entre-temps. L'indicateur d'en-tête ouvre le **panneau de synchronisation**
  (`ui/widgets/sync_panel.dart`) : attente, « Synchroniser maintenant », rejets avec motif et « Abandonner »
  confirmé — `discard` ne supprime qu'une mutation REJETÉE du compte connecté.
- **Audits** : `reviewer` OK (3 importants corrigés : contrat de sync documenté, précondition écrite, `kick`
  sans exception ni fuite d'état entre comptes) ; `security-reviewer` : 1 élevé corrigé (**E1** : l'auteur était
  lu après l'`await`, une opération de A pouvait partir étiquetée B — contre-éprouvé), faibles F1-F3 corrigés
  (log réduit au type d'erreur en debug, `discard` borné, e2e auteur absent/mal formé).
- **Exigences reportées sur B-E** : **M1** chaque handler reconnaît l'entité déjà créée en ligne sous la clé
  (sinon doublon ou faux rejet) ; **M2** une intention nomme UNE opération (`sale:<idPanier>`), jamais un geste
  générique. `writeOnlineOrQueue` n'a pas encore d'appelant : la tranche B la branche.
- **Preuve (2026-09-21)** : backend `lint:check` 0 · **82** unit · **317** e2e (23 suites, un seul passage) ;
  app `flutter analyze` propre · **+291 ~43**. Contre-épreuves : déclenchement au retour du réseau retiré → test
  en échec ; garde E1 retirée → test en échec.

**Tranche B — vente hors-ligne, livrée (2026-09-22)**
- **Serveur** : handler de sync `SALE` (`sync/handlers/sale.handler.ts`) = le MÊME cœur que `POST /sales`
  (`SalesService.createInTx`, extrait avec `replay`). TICKET seulement ; `expectedTotalTtc` obligatoire ; prix du
  tarif COURANT (écart → `SALE_TOTAL_CHANGED`) ; une vente déjà créée en ligne sous la clé est RECONNUE (M1) ;
  datée de l'appareil si plausible (0 à 72 h), sinon du sync ; échéance jugée au jour de la VENTE. (Prix :
  voir « Prix modifiable en vente » plus bas — le prix de l'appareil fait foi depuis le 2026-09-22.)
- **Caisse (audit sécu, élevé)** : la vente porte la caisse où les espèces sont entrées (`cashSessionId`,
  obligatoire hors-ligne) ; si ce n'est plus la caisse ouverte au sync → `CASH_SESSION_CLOSED`. Premier essai
  (comparer l'heure de la vente à l'ouverture de caisse) rejeté au contre-audit : contournable par une heure
  « non plausible », et faux refus sur un poste en retard. Côté app, **clôture refusée tant que la file du
  compte n'est pas vide** ; encaissement en espèces bloqué sans caisse connue ouverte.
- **Rejets tracés** : tout rejet de sync (sauf refus d'accès, déjà journalisé et qui pourrait noyer
  l'Historique) écrit un `AuditLog` `REJECT` (`SyncMutation`) — migration additive
  `20260921230000_audit_reject` ; visible dans l'Historique de l'admin (« Opération hors ligne » / « Refus à la
  synchronisation »). Raison : une vente refusée a pu avoir lieu physiquement.
- **Course en ligne ↔ sync** (même vente, réponse en ligne perdue) : le moteur répond « réessayer » quand
  `handler.existsForKey` trouve l'entité, au lieu d'un faux rejet définitif ; e2e concurrent qui échoue 5/5
  sans ce correctif.
- **App** : l'encaissement passe par `writeOnlineOrQueue` (même corps en ligne et en file, `id` = panier) ; hors
  réseau, reçu « Vente en attente de synchronisation » (jamais un ticket) ; garde « trop longtemps hors ligne ».
- **Audits** : `reviewer` PAS OK → B1 (test e2e cassé : `SALE` n'était plus « sans handler »), I1 échéance, I2
  course : corrigés ; `security-reviewer` : élevé caisse + moyens (rejets tracés, échéance) + faible (détection
  d'unicité) corrigés, tests ajoutés (remise, champs forgés, clé d'un autre compte, horloge).
- **Risques connus, à décider par MEDMEDBEN** : (1) une vente hors-ligne REFUSÉE (prix changé, stock, caisse)
  n'a que « Abandonner » côté vendeur — l'admin la voit dans l'Historique, mais aucun écran de régularisation ;
  (2) une vente À CRÉDIT hors-ligne peut être antidatée jusqu'à 72 h par un appel direct à /sync (pas de caisse
  pour la borner) ; (3) la vente reconnue en ligne puis par la file laisse une entrée d'audit « Création »
  (le contrat §4.4 audite toute mutation synchronisée ; les ventes en ligne, elles, ne le sont pas).
- **Preuve tranche B (2026-09-22)** : backend `lint:check` 0 · **82** unit · **337** e2e (24 suites, un seul
  passage) ; app `flutter analyze` propre · **+295 ~43**. Contre-épreuves (garde retirée → test en échec) :
  reconnaissance de la vente en ligne (2 tests), caisse de la vente, échéance au jour de la vente, course
  en ligne ↔ sync (5/5 en échec), garde « trop longtemps hors ligne ».

**Tranche C — caisse hors-ligne, livrée (2026-09-22)**
- **Serveur** : handler `CASH_SESSION` (`OPEN`/`CLOSE`) sur le MÊME cœur que les routes (`openInTx`/`closeInTx`
  /`replayOpen` extraits ; `actor` null → seule la sync audite, pas de doublon ; `alreadyRecordedOnline` quand
  la file ne fait que reconnaître un geste fait en ligne). Id de caisse généré par l'appareil ; ouverture et
  clôture datées de l'appareil (borne plausible commune, `plausibleDeviceTime`). `existsForKey` limité à l'auteur.
- **App** : état de caisse = dernière ouverture/clôture EN FILE, sinon dernier état serveur conservé sur
  l'appareil (`LocalSettingsStore`, par compte). Hors ligne sans état connu : « Caisse indisponible », aucune
  ouverture proposée. Clôture : synchro tentée d'abord, puis PAR LA FILE si des ventes attendent encore
  (remplace le refus de la tranche B) ; vente dont la caisse est encore en file → par la file aussi. Badge
  « Caisse ouverte · en attente de synchronisation ».
- **Bug latent corrigé** : « Ouvrir la caisse » lisait un provider auto-libéré jamais surveillé → « Magasin
  introuvable » (même en ligne).
- **Audits** : `reviewer` PAS OK (B1 « Ouvrir hors ligne » après redémarrage → cascade de rejets ; B2 état
  local bloqué après rejet ; I1 dates de caisse ; I2 vente avant l'ouverture en file ; docs) et
  `security-reviewer` (élevé = B1 ; audit trompeur ; dates ; `existsForKey`) : tout corrigé — l'état local
  dérive désormais de la file, un rejet ou une confirmation le recale sans intervention.
- Non fait, assumé : note d'une clôture rejouée non comparée (aucun impact argent).
- **Preuve tranche C (2026-09-22)** : backend `lint:check` 0 · **82** unit · **344** e2e (25 suites, un seul
  passage) ; app `flutter analyze` propre · **+298 ~43** ; **43 captures** régénérées (écran Vente vérifié).
  Contre-épreuves : reconnaissance d'une ouverture faite en ligne ; mémoire du dernier état de caisse (2 tests).
- **Prochaine étape précise** : tranche D — réception hors-ligne (spec §15). Handler `RECEPTION` sur le cœur de
  `ReceptionsService` (à extraire en `createInTx`/`replay`, comme la vente), `existsForKey` (clé de réception, par
  auteur), reconnaissance en ligne ; côté app, formulaire de réception via `writeOnlineOrQueue` (intention
  `reception:<idFormulaire>`), reçu « en attente ». Attention : prix d'achat pris de la COMMANDE (audit P0 #7).

**Tranche D — réception hors-ligne (2026-09-22)**
- **Serveur** : handler `RECEPTION` sur le MÊME cœur que `POST /receptions` (`createInTx`/`replay` extraits ;
  `actor` null → seule la sync audite) : surlivraison refusée, prix d'achat de la COMMANDE (celui du bon ignoré),
  hors commande = ADMIN, stock par le journal, coût et dette mis à jour. Réception déjà faite en ligne sous la
  clé → reconnue (`alreadyRecordedOnline`) ; `existsForKey` par auteur ; datée de l'appareil (borne plausible).
- **App** : `ReceptionsActions.receive` via `writeOnlineOrQueue` (id = clé d'intention du formulaire) ; sans
  réseau, message « enregistrée sur cet appareil — pas encore en stock ».
- **Limite connue** : la liste des commandes et le formulaire se chargent EN LIGNE. La réception hors-ligne couvre
  donc la coupure PENDANT la saisie, pas un dépôt sans réseau dès l'ouverture de l'écran. Mettre les commandes
  engagées en cache local = P1 n°14 (« réception mobile »).
- **Audits** : `security-reviewer` — aucun critique/élevé ; corrigés : audit hors-ligne aussi détaillé qu'en
  ligne (lignes, quantités, prix), une réception synchronisée TARD n'écrase plus un coût plus récent, tests « id
  réutilisé » et « clé d'un autre compte ». `reviewer` PAS OK → corrigés : test e2e cassé (`RECEPTION` n'est plus
  « sans handler » → `PURCHASE_ORDER`, qui restera en ligne), **course en ligne ↔ sync** (la réception relue SOUS
  le verrou de commande, sinon faux rejet « surlivraison » — e2e concurrent : 3/3 en échec sans le correctif),
  convention d'audit unique (`offline` OU `alreadyRecordedOnline`, alignée sur la vente).
- **Preuve tranche D (2026-09-22)** : backend `lint:check` 0 · **82** unit · **363** e2e (26 suites, un seul
  passage) ; app analyze propre · **+301 ~43**. Contre-épreuves : reconnaissance en ligne, relecture sous verrou
  (3/3), coût non écrasé par une réception tardive.
- **Prochaine étape précise** : tranche E — handlers `TRANSFER` (étapes demande/préparation/réception du
  `TransfersService`, à découper comme la réception : `replay` + cœur dans la transaction, relecture sous le
  verrou `lockTransfer`), comptage d'inventaire (`INVENTORY`, lignes comptées seulement — la VALIDATION reste en
  ligne, geste admin), règlements clients (`CUSTOMER_PAYMENT`, caisse de la vente comme pour la vente en
  espèces). Chaque handler : `existsForKey` par auteur, test « en ligne puis file » et test concurrent.

**Prix modifiable en vente — décision MEDMEDBEN du 2026-09-22 (livrée, auditée)** — remplace l'ancien rejet
« prix changé pendant la coupure » :
- Le vendeur (comme l'admin) **modifie le prix d'une ligne** en vente (crayon, badge « Prix modifié ») ; plancher
  = **dernier prix d'achat** (serveur ET app, ligne nette de remise comprise → `PRICE_BELOW_COST`).
- **Le vendeur voit le coût d'achat** (`cost.read` ajoutée au rôle VENDEUR ; le coût est désormais gardé dans la
  base locale). Choix de MEDMEDBEN après l'audit : garder le coût secret tout en le prenant pour plancher le
  laissait deviner par essais.
- Hors ligne, **le prix affiché fait foi**. En ligne, une ligne NON modifiée doit être au tarif courant (sinon
  409 `SALE_TOTAL_CHANGED` : catalogue en retard). `SaleLine.tariffPriceHt` (migration additive + reprise) garde
  le tarif à côté du prix appliqué ; seules les lignes `priceEdited` sont tracées dans l'Historique.
- **Ni coût ni tarif** → `PRICE_NOT_DEFINED` : le produit ne se vend pas tant que l'admin ne lui a pas donné un
  prix — **validé par MEDMEDBEN le 2026-09-22**.
- **À REVOIR PLUS TARD (MEDMEDBEN, 2026-09-22)** : produit jamais réceptionné (coût inconnu) → le vendeur ne
  descend pas sous le plus bas de ses tarifs. Règle provisoire laissée en place ; à rediscuter (ex. prix
  minimum saisi par l'admin, ou coût saisi à l'import du stock initial).
- Audits : `security-reviewer` (2 élevés : coût révélé, vente à 0 ; 3 moyens : remise sous le coût, prix
  toujours envoyé en ligne, historique trompeur) et `reviewer` (même bloquant) → tout corrigé ou tranché.
- **Preuve (2026-09-22)** : backend `lint:check` 0 · **82** unit · **352** e2e (25 suites) ; app analyze propre ·
  **+300 ~43** ; **43 captures**. Contre-épreuves : plancher (3 tests), prix non modifié ≠ tarif en ligne, plancher
  sur le net (remise admin).


### ✅ P0 #11 HISTORIQUE / AUDIT — LIVRÉ ET AUDITÉ (2026-09-21 · **MEDMEDBEN**)
Spec §24. Chaque feature écrit déjà son journal DANS sa propre transaction (`writeAudit`) ; P0 #11 livre la
**lecture**, réservée à l'ADMIN. **Aucune migration** : `AuditLog` et ses index étaient complets.

**Plus aucune route au contrat 501.** L'audit était la dernière : `ApiContractModule` et `notImplemented` sont
supprimés, et le test « contrat figé → 501 » n'a plus d'objet. Le code d'erreur `NOT_IMPLEMENTED` reste (la
synchronisation s'en sert pour une opération sans handler).

**Backend** (`src/audit/`) — `GET /audit-logs` : ADMIN + `audit.read` + **`@RequireFreshAccess()`** — l'accès est
relu EN BASE, pas dans le seul jeton : un admin rétrogradé perd la vue du journal **immédiatement**, pas 15 minutes
plus tard. Filtres : type d'objet, objet précis, membre, action, période. Les jours `from`/`to` sont des jours
civils d'**Alger** (minuit à minuit), `to` inclus. Du plus récent au plus ancien, tri en liste blanche, nom de
l'auteur joint pour la lecture (« Système » quand c'est le serveur qui agit, ex. détection d'un vol de session).
**Aucune route d'écriture** : le journal est immuable par construction (règle 7), éprouvé (POST/PATCH/DELETE → 404).

**App** — `features/audit/`, destination **« Historique »** (ADMIN seul) : filtres objet / action / période
(7 jours par défaut, 30 jours, tout), vraie pagination « Afficher plus (N sur M) » — le journal grossit vite, une
page plafonnée aurait tronqué en silence (la leçon du planning). Le détail d'une entrée montre **champ par champ
ce qui a changé** (`auditChanges`, testé unitairement). Trois choix de lecture :
- **les montants, tracés en centimes, se lisent en dinars** — « Prix HT : 1 200,00 DA → 1 350,00 DA », jamais
  « 120000 ». La modification de prix est la première action sensible de la spec : la lire de travers serait une
  faute. Les quantités, tracées en chaînes, ne sont pas confondues (testé). Contre-épreuve : formatage retiré →
  deux tests échouent ;
- **les opérations de sécurité se lisent** : « Vol de session présumé : toutes les sessions coupées » au lieu de
  `REFRESH_TOKEN_REUSE_DETECTED` ;
- une création n'a pas d'« avant », une annulation pas d'« après » : on montre ce qui existe.

**Défaut ANTÉRIEUR révélé et corrigé : sur téléphone, des écrans étaient INACCESSIBLES.** Le menu « Plus » de la
coquille mobile était une colonne FIXE dans une feuille du bas. Avec « Historique », l'admin a 11 destinations :
les dernières sortaient de l'écran. Toutes les captures mobiles passant par « Plus » ont échoué d'un coup, ce qui
l'a révélé. Menu rendu défilant, et un test le garde sur un petit téléphone (360 × 640) : la DERNIÈRE entrée doit
s'ouvrir. **Contre-épreuve : colonne fixe → « RenderFlex overflowed by 144 pixels ».**

**Audits P0 #11 (2026-09-21)** — `reviewer` : **PAS OK** (2 bloquants) · `security-reviewer` : **NON CONFORME**
(1 important). Tout ce qui comptait est corrigé :
- **B1 — j'avais annoncé « les montants se lisent en dinars » : c'était FAUX pour une partie d'entre eux.**
  L'écart de caisse du rapport Z (`difference`, le chiffre le plus sensible de la clôture) restait en centimes,
  et les montants IMBRIQUÉS dans des lignes (prix des réceptions et des commandes, tarifs d'un produit)
  s'affichaient bruts, mêlés d'identifiants. L'affichage est désormais RÉCURSIF et reconnaît `difference`
  (celui d'un inventaire, une quantité en chaîne, n'est pas confondu). 2 tests.
- **B2 — course entre changement de filtre et « Afficher plus ».** La page de l'ANCIEN filtre s'ajoutait sous le
  NOUVEAU : le journal montrait des entrées hors du filtre affiché. Le filtre est mémorisé au départ de l'appel,
  la réponse périmée est ignorée. Test qui reproduit la course (page 2 retenue, filtre changé, page libérée).
  **Contre-épreuve : garde retirée → l'entrée de l'ancien filtre réapparaît.**
- **Important (sécurité) — `?page=1e308` : 500 sur TOUTES les listes du projet.** `page` n'avait pas de borne
  haute ; le décalage dépassait ce que Prisma accepte. Corrigé une fois dans le DTO de pagination PARTAGÉ
  (`@Max(1_000_000)`), éprouvé sur 4 listes et sur le journal. **Contre-épreuve : borne retirée → 500.**
- « Afficher plus » en échec n'était signalé nulle part : l'écran l'annonce, la liste chargée reste (testé) ;
  doublons de pagination par décalage éliminés (testé) ; refus d'accès vérifiés à la main par l'audit
  (compte désactivé, session révoquée, mot de passe à changer, sans jeton) désormais FIGÉS par un test.
- **Prévention pour la P0 #12** : `auditNewValue` devient OBLIGATOIRE dans le contrat des handlers de
  synchronisation, et le moteur ne retombe plus sur le payload BRUT du client — la P0 #12 va ajouter une
  dizaine de handlers ; un oubli aurait fait entrer des données client arbitraires dans le journal.
- **Une consigne que j'avais écrite FAUSSE, corrigée avant de te la transmettre** : j'avais noté dans
  `docs/DEPLOYMENT.md` qu'il suffisait de retirer les droits de modification sur le journal au rôle de
  l'application. Or l'infra n'a qu'UN rôle (`magasin_prod`), propriétaire de la base et exécutant des
  migrations : un propriétaire se rend à lui-même ce qu'on lui retire. Le document dit maintenant la vérité —
  **journal NON protégé au niveau de la base aujourd'hui** — et ce qu'il faut changer (deux rôles, deux URL).

**Contre-épreuves réellement exécutées** :
- `@RequireFreshAccess()` retiré → l'admin rétrogradé garde la vue du journal (le test échoue) ;
- garde du filtre retirée → l'ancienne page s'ajoute sous le nouveau filtre ;
- borne de `page` retirée → 500 sur 4 listes ;
- formatage des montants retiré → les centimes bruts réapparaissent (2 tests échouent) ;
- menu « Plus » non défilant → débordement de 144 px, dernière entrée inaccessible.

**Preuve finale (2026-09-21, après audits)** : backend `lint:check` **0** · **81** unit · **314** e2e (23 suites,
**un seul passage**) dont **8** historique ; app `flutter analyze` propre · **+275 ~43** dont **18** historique et 1
coquille mobile · **43** captures (42 : journal, 43 : détail d'une modification de prix).

**Non fait, tracé** : le journal n'est pas protégé AU NIVEAU DE LA BASE contre un `UPDATE`/`DELETE` direct (aucune
route ne le permet, mais un accès SQL le pourrait). Il faut séparer le rôle propriétaire (migrations) du rôle de
l'application — changement d'infra à décider, décrit dans `docs/DEPLOYMENT.md`. Ne jamais supprimer un compte en
base : la clé du journal est en `ON DELETE SET NULL`, ses entrées passeraient à « Système ». Pas d'export PDF/Excel du journal (P1 n°21) ; le filtre
par membre existe côté serveur mais pas dans l'écran.

### ✅ P0 #10 PLANNING HEBDOMADAIRE — LIVRÉ ET AUDITÉ (2026-09-21 · **MEDMEDBEN**)
Le stub 501 des tâches est remplacé par la vraie feature (`backend/src/planning/`,
`app/lib/features/planning/`). Spec §23. **Aucune migration** : `PlanningTask` était complet depuis la Phase 0.
Le stub de l'audit (P0 #11) partageait le fichier du planning : il vit désormais dans `src/audit/audit.controller.ts`.

**Qui fait quoi** (`docs/permissions.md`) : l'ADMIN planifie, modifie, réassigne et supprime ; chaque membre ne
voit et n'exécute **QUE ses tâches** — le serveur cloisonne, quel que soit le filtre envoyé. Une tâche d'un
collègue répond **404**, pas 403 : on ne confirme même pas qu'elle existe.

**Machine à états** `A_FAIRE → EN_COURS → TERMINEE`. `EN_RETARD` n'est **jamais stocké** : il est calculé
(`isLate`) à partir du **LENDEMAIN** de l'échéance — exactement la règle des ventes à crédit, sinon une tâche
due aujourd'hui passerait en retard dès 1 h du matin à Alger. Les jours (`scheduledFor`, `dueDate`) sont des
jours civils `AAAA-MM-JJ`, jamais des instants ; côté app ils restent des chaînes et ne passent par aucun
`DateTime` (un jour civil n'a pas de fuseau — le convertir le ferait glisser).

**Choix assumés** :
- **Résultat OBLIGATOIRE pour terminer** (spec §23 : « résultat ») — une tâche close sans résultat ne dit rien
  à qui l'a planifiée. On peut terminer sans avoir « commencé » : une tâche de cinq minutes n'a pas besoin
  de deux clics.
- **Suppression** par l'admin **seulement tant que personne n'a commencé** (une tâche entamée ou close a une
  histoire). Sans cette porte, une tâche créée par erreur restait visible par l'employé pour toujours.
- **Une tâche close ne se réécrit plus** (ni modification, ni seconde fin qui écraserait le résultat).
- **Aucune tâche confiée à un compte désactivé** : personne ne la verrait.
- **Transitions en COMPARE-AND-SWAP** (une requête conditionnée par le statut attendu) plutôt qu'un quatrième
  verrou `FOR UPDATE` copié-collé : même garantie (l'admin qui supprime pendant que le membre termine → un seul
  passe), une requête, rien à maintenir. Même motif que le changement de mot de passe.
- **Audit** : seuls les gestes de l'ADMIN (créer, modifier, supprimer). Démarrer et terminer sont le travail
  courant du membre, tracés dans la tâche elle-même (`completedAt`, `result`) — ils ne polluent pas la vue
  d'audit (spec §24, comme les ventes courantes). Testé.
- **Filtres qui se cumulent** : `status=A_FAIRE&late=true` = pas commencées ET en retard ; `status=TERMINEE&late=true`
  est refusé (contradictoire). Défaut que je me suis repris AVANT les tests : dans ma première version, `late`
  écrasait `status` en silence — exactement ce que la revue m'avait reproché sur l'inventaire.

**Routes** : `GET /planning-tasks` (filtres `status`, `open`, `late`, `assignedToId` — admin seul) ·
`GET /planning-tasks/:id` · `POST /planning-tasks` · `PATCH /planning-tasks/:id` · `DELETE /planning-tasks/:id` ·
`POST /:id/start` · `POST /:id/complete`. Écarts au contrat figé (qui n'avait que GET liste et POST) : tout le
reste est ajouté — le contrat ne permettait ni d'exécuter une tâche, ni de la corriger.

**Audits P0 #10 (2026-09-21)** — `reviewer` : **PAS OK** (4 bloquants) · `security-reviewer` : **NON CONFORME**
(1 important, 5 mineurs). Tout ce qui comptait est corrigé :
- **B1 — une tâche EN RETARD ne se réassignait pas.** L'app renvoyait tous les champs, dont l'échéance passée
  inchangée, que le serveur refusait. Et le sélecteur de date **plantait** (date initiale avant la première date
  permise). L'app n'envoie plus que les champs RÉELLEMENT modifiés (`planningChanges`, testé) et le sélecteur part
  d'aujourd'hui. **Contre-épreuve : bornage retiré → le test reproduit exactement le plantage.**
- **B2 — la liste perdait les tâches RÉCENTES.** Plafond de 200, tri du plus ancien au plus récent, tâches closes
  jamais retirées : en ~13 semaines, les nouvelles disparaissaient en silence. L'écran a désormais trois vues —
  **À faire** (ouvertes, le plus urgent d'abord), **En retard**, **Terminées** (la plus récente d'abord, nouveau tri
  `completedAt`) — et dit « N tâches affichées sur M » si une page est tronquée. Filtre serveur `open` ajouté.
- **B3 — test instable et message faux.** Suppression et fin simultanées pouvaient répondre « déjà terminée » pour
  une tâche supprimée. Quand le compare-and-swap ne touche rien, on RELIT pour dire la vraie raison : disparue ou
  passée à un autre → 404, sinon → 409.
- **B4 — un vrai trou dans le cloisonnement.** Entre la lecture et l'écriture, si l'admin réassignait la tâche,
  l'ancien titulaire pouvait encore la terminer (son résultat restait sur la tâche du nouveau). Le compare-and-swap
  d'un membre porte désormais aussi le PROPRIÉTAIRE (`assignedToId`).
- **Important (sécurité) — `"id": null` rendait 500, et PAS SEULEMENT ICI.** `@IsOptional()` laisse passer `null`
  sans rien valider ; l'id client atteignait Prisma sur **toutes** les routes de création. Corrigé une fois pour
  toutes (CONVENTIONS règle 1) par un décorateur PARTAGÉ `ClientGeneratedId` (`common/validation.ts`), appliqué
  aux **15 occurrences dans 12 DTO** : clients, fournisseurs, produits, emplacements, stock, ventes, achats,
  réceptions, transferts, inventaire, planning et **charges utiles de synchronisation**. Nouveau test
  `client-id.e2e-spec.ts` (fournisseurs, clients, produits, avec des corps par ailleurs VALIDES pour qu'aucune
  autre erreur ne masque le défaut). **Contre-épreuve : décorateur rendu permissif → les trois modules retombent en 500.**
- Mineurs traités : renvoi du même id avec un AUTRE contenu → 409 (contrat `assertSameMutation`/`runOnce`, comme
  partout, au lieu d'un 201 silencieux) ; **l'ADMIN qui démarre ou termine la tâche d'un autre laisse une trace**
  d'audit (`onBehalfOf`) — sans elle son résultat passait pour celui du membre ; un PATCH sans changement n'écrit
  plus de trace identique ; l'instantané d'audit porte `description` et `createdById` (une tâche supprimée se
  relit) ; `from`/`to` et `locationId` **retirés** (jamais utilisés par l'app, jamais prouvés).
- Relecture de mes propres captures : la fixture de capture ignorait la vue et montrait une tâche « Terminée »
  dans « À faire ». Corrigée : la capture montre ce que l'app montrera.

**Contre-épreuves réellement exécutées** :
- cloisonnement retiré → « chacun ne voit QUE ses tâches » échoue ;
- compare-and-swap retiré → « une tâche close ne se réécrit plus » échoue (le résultat était écrasé) ;
- décorateur d'id client rendu permissif → 500 sur fournisseurs, clients et produits ;
- bornage du sélecteur de date retiré → plantage `initialDate must be on or after firstDate`.

Non fait, tracé : le démarrage (EN_COURS) n'est pas daté (aucune colonne `startedAt`, et l'ajouter demande une
migration) ; la course admin-réassigne / membre-termine n'est pas éprouvée par un test DÉTERMINISTE (seul le cas
séquentiel l'est) ; un formulaire renvoyé après une suppression recrée la tâche ; ces corrections n'ont pas été
ré-auditées par les subagents — la preuve est la suite complète et les contre-épreuves ci-dessus.

**App** — `features/planning/` : destination **« Tâches »** (les 3 rôles, comme la spec mobile le nomme) ;
badge où **le retard prime sur le statut** ; l'admin filtre par membre et « en retard seulement », crée et
modifie par un panneau (membres ACTIFS seulement, jours au calendrier), supprime une tâche À FAIRE avec une
confirmation qui rappelle la trace d'audit ; le membre commence, puis termine dans un dialogue qui exige le
résultat. `isoDay` remonté des ventes vers `core/dates.dart` (partagé), `formatIsoDay` ajouté.
Captures **39** (planning de l'équipe, desktop), **40** (nouvelle tâche, desktop), **41** (fin de tâche, mobile).
Bémol noté : sur mobile, la barre de filtres de l'admin prend deux lignes.

**Preuve finale (2026-09-21, après audits)** : backend `lint:check` **0** · **81** unit · **306** e2e (22 suites,
**un seul passage**) dont **21** planning et **3** id client ; app `flutter analyze` propre · **+256 ~41** dont
**16** planning · **41** captures. Le test « contrat figé → 501 » visait `/api/planning-tasks` : reporté sur `/api/audit-logs`,
la DERNIÈRE route encore au contrat.

**Non fait, tracé** : pas de vue « semaine » en calendrier (les trois vues triées couvrent le besoin ; une
grille viendra si MEDMEDBEN la veut) ; pas de notification « tâche du
jour / en retard » (P1 n°16) ; le planning est **en ligne uniquement** (P0 #12) ; ordre des onglets mobiles
de la spec (`Accueil | Ventes | Stock | Tâches | Plus`) non appliqué — « Tâches » arrive après « Stock » dans
le menu, mais sur mobile il passe sous « Plus ».

### 🚧 P0 #9 INVENTAIRE — CODE LIVRÉ, AUDITS EN COURS (2026-09-21 · **MEDMEDBEN**)
Le stub 501 de l'inventaire est remplacé par la vraie feature (`backend/src/inventory/`,
`app/lib/features/inventory/`). Spec §22 : « comparer théorique ↔ physique ».

**Migration ADDITIVE `20260921013306_document_type_inventaire`** : `ALTER TYPE "DocumentType" ADD VALUE
'INVENTAIRE'` (numérotation `INV-AAAA-NNNNN` par le générateur unique). Rien d'autre à changer — le schéma
Phase 0 portait déjà `Inventory` + `InventoryLine` au complet.

**Trois temps, et UN SEUL touche le stock** :
1. **lancement** : les lignes sont créées, le théorique figé — c'est la feuille de comptage. Aucun mouvement.
2. **comptage** : le physique est saisi, reprenable (`done: false` garde EN_COURS, `done: true` clôt en
   TERMINE). Le théorique de la ligne est **RELU à cet instant** : c'est ce que le système croyait quand le
   compteur avait le produit en main, donc le seul théorique honnête pour l'écart. Aucun mouvement.
3. **validation (ADMIN SEUL)** : un mouvement `AJUSTEMENT_INVENTAIRE` par écart, **en DELTA** (règle 2 :
   jamais une quantité absolue). Le magasinier compte, il ne valide jamais — éprouvé par un 403.

**`INVENTORY_STALE_COUNT` — je m'étais trompé, les deux audits l'ont démonté.** J'avais refusé de valider
dès qu'une VENTE avait bougé le stock depuis le comptage, « pour ne pas l'écraser ». C'était faux : comme
l'ajustement est un **delta**, il ne peut rien écraser. Théorique 50, compté 47 → −3 ; une vente de 5 laisse
45 ; appliquer −3 donne **42**, exactement la vérité physique (47 comptés − 5 vendus). Pire, mon refus
créait une **impasse** : l'inventaire n'était plus ni validable (409) ni recomptable (un TERMINE ne se
recompte pas), et le message ordonnait un recomptage que l'API interdisait. Dans un magasin qui vend toute
la journée, c'était le cas NORMAL, pas le cas rare.
La garde est donc **restreinte à ce qu'elle protège vraiment** : un AUTRE inventaire a déjà corrigé ces
produits depuis ce comptage (deux inventaires qui se chevauchent appliqueraient deux fois le même écart).
Une vente ou une réception ne bloquent plus rien. Deux tests : la vente qui passe et donne 42, la double
correction refusée.

**Routes** (contrat 501 retiré, `InventoryModule` déclaré) : `POST /inventories` · `GET /inventories`
(filtres `status`, `pendingValidation`) · `GET /inventories/:id` · `POST /:id/count` · `POST /:id/validate`.

**Trois écarts assumés par rapport au contrat figé**, chacun pour une raison :
1. **`GET /inventories/:id` ajouté** : complète la lecture du contrat (liste seule). L'app ne s'en sert pas
   aujourd'hui — l'écran travaille sur l'objet de la liste, qui porte déjà les lignes.
2. **`SubmitCountDto.done`** : sans lui, un comptage ne pouvait jamais être déclaré terminé et la validation
   n'avait aucune porte d'entrée. Même motif que `prepare` des transferts.
3. **`CreateInventoryDto.productIds`** : un inventaire TOURNANT doit figer un théorique, donc connaître son
   périmètre au lancement. Aucun lien produit↔zone n'existe dans le schéma ; la liste explicite est la seule
   option qui n'invente rien. `zone` reste le libellé libre que le schéma prévoyait. COMPLET les refuse.

**Garde-fous, tous testés** : verrou `lockInventory` point d'entrée UNIQUE de toute écriture ; on n'inventorie
ni le transit ni une position (MAGASIN/DEPOT seuls) ; un produit étranger à l'inventaire est refusé ; un
inventaire TERMINE ne se recompte plus ; la validation exige TERMINE ; rejouée elle rend l'inventaire déjà
validé (aucun second ajustement) ; `clientMutationId` obligatoire au lancement ; tri et statut en liste
blanche (`constructor`/`toString` compris, cf. le défaut trouvé en P0 #8) ; chaque étape auditée
(CREATE → ADJUST → VALIDATE), la validation traçant le nombre de lignes ajustées.

**Audits P0 #9 (2026-09-21)** — `reviewer` : **PAS OK** (3 bloquants) · `security-reviewer` : **CONFORME**
sur le périmètre sécurité (0 critique, 0 important) mais **NON CONFORME** global (2 importants). Les deux
convergeaient ; tout est corrigé :
- **Bloquant/important : le garde-fou périmé et son impasse** → voir ci-dessus. Justifications, Swagger,
  message d'erreur, code d'erreur et commentaire de test réécrits : ils décrivaient une protection qui
  n'existait pas.
- **Important : un produit DÉSACTIVÉ portant du stock rendait l'inventaire entier non validable.** Le
  journal refuse toute sortie sur un produit inactif ; un écart négatif tombait dessus, et comme tout se
  joue dans une transaction, plus rien ne passait — le stock résiduel était gelé pour toujours, aucun autre
  chemin ne le soldant. Corrigé **de façon généralisée** dans `StockLedgerService` (CONVENTIONS règle 1) :
  les RÉGULARISATIONS (`INVENTORY` et `MANUAL`) ne sont plus bloquées par une désactivation — la
  déclaration de perte/casse souffrait du même défaut, elle est réparée du même coup. C'est exactement ce
  qu'exige l'invariant 4 (« testé avec l'entité désactivée »).
- **Bloquant : une règle tenue UNIQUEMENT par l'UI** (règle 1). L'écran refusait de terminer un comptage
  incomplet, le serveur l'acceptait : un inventaire pouvait finir « Ajusté » avec 499 lignes jamais comptées.
  Le serveur refuse désormais `done: true` tant qu'une ligne n'a pas de quantité.
- Ménage demandé par la revue : `pendingValidation` (jamais appelé, jamais testé, et il écrasait
  silencieusement `status`) et `CountLineDto.note` (mort de bout en bout) **supprimés** ; action d'audit du
  comptage `ADJUST` → `UPDATE` (il n'ajuste rien, le journal se lisait à l'envers) ; garde `completedAt`
  nul passée en fail-closed ; motif de quantité du DTO commenté (il refuse le négatif à dessein, ne pas le
  « factoriser ») ; tests ajoutés pour le produit dupliqué, l'état vide et l'état erreur de l'écran, et le
  libellé « Reprendre le comptage ».
- Justification corrigée : `GET /inventories/:id` n'est PAS appelé par l'app (l'écran travaille sur l'objet
  de la liste, qui porte déjà les lignes) — la route reste, gardée et testée, mais ce n'était pas la raison.
- **Point laissé ouvert, assumé** : le masquage du théorique avant comptage est **cosmétique**. L'API le
  renvoie sur toutes les lignes, et le magasinier a de toute façon accès à l'écran Stock. C'est un
  garde-fou d'ergonomie, pas de sécurité. À trancher si tu veux un comptage réellement aveugle.

**Contre-épreuves réellement exécutées** :
- verrou retiré → « deux validations SIMULTANÉES » applique l'ajustement **deux fois** (stock à 38 au lieu
  de 44) ;
- exception de régularisation retirée → « produit DÉSACTIVÉ » échoue (stock gelé) ;
- garde du comptage incomplet retirée → « comptage INCOMPLET » échoue.

**App** — `features/inventory/` : destination « Inventaire » (ADMIN|MAGASINIER + `inventory.create`) ; liste
avec avancement puis écarts (« 1 écart(s) sur 2 produit(s) · tournant · Zone B »), badges **En cours /
À valider / Ajusté** ; lancement (lieu, type complet/tournant, zone, produits cochés) ; comptage reprenable.
**Choix d'écran assumé** : le théorique n'est PAS pré-rempli ni affiché avant le premier comptage — afficher
la réponse attendue est le meilleur moyen d'obtenir un comptage complaisant. Il apparaît ensuite, à côté de
l'écart. La validation demande une confirmation qui annonce l'effet réel (« le stock sera corrigé d'autant,
chaque correction laissera un mouvement daté à ton nom »). Captures **36** (liste desktop), **37** (comptage
mobile), **38** (écarts desktop).

**Preuve finale (2026-09-21, après audits)** : backend `lint:check` **0** · **81** unit · **282** e2e
(20 suites, **un seul passage**) dont **18** inventaire ; app `flutter analyze` propre · **+240 ~38** dont
**13** inventaire · **38** captures. Le test « contrat figé → 501 » visait `/api/inventories` : reporté sur
`/api/planning-tasks`.

**Non fait, tracé** : `InventoryLine.note` est alimentée par le comptage mais aucun écran ne l'affiche ;
l'inventaire est **en ligne uniquement** (pas de handler de sync — P0 #12) ; pas d'export PDF/Excel des
écarts (P1 n°21) ; aucun statut d'abandon (la machine à états figée n'en prévoit pas : un inventaire
délaissé reste EN_COURS).

**Relevé par l'audit sécurité, HORS feature, à toi de trancher** : `.claude/settings.json` autorise
`Bash(cp .env.example .env)` et `Bash(cp .env.minio-root.example .env.minio-root)` — deux commandes qui
**écrasent sans confirmation un `.env` local renseigné**. Les variantes `*.reviewtmp` suffisaient. Je n'y
touche pas : ce sont tes garde-fous, et le harnais m'interdit de modifier mes propres permissions.

### 🚧 P0 #8 TRANSFERTS MAGASIN ↔ DÉPÔT — BACKEND LIVRÉ (2026-09-21 · **MEDMEDBEN**)
Le stub 501 des transferts est remplacé par la vraie feature (`backend/src/transfers/`). **Aucune migration** :
le schéma Phase 0 portait déjà `Transfer` + `TransferLine` au complet (y compris `shippedQuantity`).

**Le stock ne bouge qu'à DEUX moments, jamais à la demande ni à la préparation** (règle 2, tout par
`StockLedgerService`) :
- **expédition** : DÉPÔT − préparé (`TRANSFERT_SORTIE`), TRANSIT + préparé (`TRANSFERT_ENTREE`) ;
- **réception** : TRANSIT − expédié, MAGASIN + reçu, et **l'écart RETOURNE au dépôt** (mouvement commenté
  « écart de transfert »). Décision : le transit ne porte aucune projection déclarable en perte — y laisser
  du stock le gèlerait pour toujours. Rendu au dépôt, le manquant se constate par une déclaration de perte.
- Conséquence tenue : **le produit n'est vendable au magasin qu'APRÈS réception** (spec §17), éprouvé par un test.

**Routes** (contrat 501 retiré, `TransfersModule` déclaré) : `POST /transfers` · `GET /transfers` (filtres
`status` — statut exact ou `EN_COURS` — et `mine`) · `GET /transfers/:id` · `POST /:id/accept` ·
`POST /:id/prepare` · `POST /:id/ship` · `POST /:id/receive` · `POST /:id/cancel`.

**Cinq écarts assumés par rapport au contrat figé** (les stubs ; aucun artefact OpenAPI versionné
n'existe, donc aucun client généré n'est cassé), chacun pour une raison :
1. **`POST /:id/accept` ajouté.** Sans lui, `ACCEPTEE` et `EN_PREPARATION` étaient deux valeurs d'enum mortes
   alors que `docs/plan.md` fige la machine à états. `accept` = « le dépôt s'en charge » ; `prepare` avec
   `done: false` = préparation en cours reprenable (EN_PREPARATION), `done: true` = PREPAREE.
2. **`fromLocationId` / `toLocationId` deviennent facultatifs.** Le périmètre est 1 magasin + 1 dépôt : le
   serveur les résout (DEPOT actif → MAGASIN actif) et refuse tout identifiant d'une autre espèce — un
   transfert n'inverse pas le sens du flux. Une liste déroulante de moins à se tromper côté app.
3. **`GET /transfers` est gardé par les RÔLES seuls** (les 3). Le stub exigeait `transfer.request`, que le
   **magasinier n'a pas** : la route aurait répondu 403 à celui qui prépare. Aucune permission existante
   n'est commune aux trois rôles et en inventer une dépasserait `docs/permissions.md`.
4. **`clientMutationId` passe d'optionnel à OBLIGATOIRE** à la création (règle 8) : une demande renvoyée
   après une coupure ne doit pas devenir deux demandes. Un appelant écrit sur le stub reçoit 400.
5. **`POST /:id/cancel` exige un corps `{ status }`** (`REFUSEE` | `ANNULEE`) alors que le stub n'en
   prenait aucun : c'est la seule façon de distinguer « le dépôt ne suivra pas » de « le demandeur
   renonce », que la matrice sépare. Un appelant écrit sur le stub reçoit 400.

**Matrice appliquée à la lettre** (`docs/permissions.md`) : le vendeur demande et réceptionne, le magasinier
accepte/prépare/expédie, le refus (`REFUSEE`) vient du dépôt (ADMIN|MAGASINIER), l'annulation (`ANNULEE`) de
l'ADMIN **ou du vendeur auteur de la demande** — un autre vendeur reçoit 403.

**Garde-fous, tous testés** : verrou de ligne `lockTransfer` (`SELECT … FOR UPDATE`) point d'entrée UNIQUE de
toute transition, comme `lockOrder` pour les commandes ; surpréparation et surréception refusées ; expédition
à vide refusée (« refusez la demande ») ; plus d'annulation après expédition (règle 7) ; pas de double
réception ; `clientMutationId` obligatoire à la demande (renvoi identique → même demande, autre contenu → 409) ;
tri en liste blanche ; statut de filtre inconnu → 400 ; produit désactivé → plus de demande possible ;
chaque étape auditée avec son auteur et l'avant/après.

**Corrigé dans le journal de stock partagé** (`StockLedgerService`, règle 1 de CONVENTIONS — un invariant se
corrige à l'endroit UNIQUE) :
- **Un produit désactivé pendant qu'un transfert roule bloquait sa réception** : la sortie du TRANSIT était
  refusée comme une vente, et la marchandise restait coincée sans aucun chemin de régularisation. La règle
  « produit désactivé = plus de sortie » ne s'applique plus au TRANSIT, qui ne porte pas de stock vendable
  mais de la marchandise déjà partie. Contre-épreuve : exception retirée → le test échoue.
- `StockMovement.sourceLocationId` / `destinationLocationId` sont enfin **renseignés** (le schéma Phase 0 les
  prévoyait « pour la traçabilité d'un transfert » et rien ne les remplissait).

**Contre-épreuves réellement exécutées** :
- verrou retiré → « expédition et refus SIMULTANÉS » laisse passer **les deux** (200/200 au lieu de 200/409) ;
- exception TRANSIT retirée → « produit désactivé : un transit en cours arrive quand même » échoue.

**App** — `features/transfers/` : destination « Transferts » (proposée à qui tient un bout du flux) ;
liste avec statut, priorité et AVANCEMENT lisible (« préparé 36 sur 40 demandés ») ; formulaire de demande
(priorité, lignes, commentaire, clé d'intention stable) ; un seul écran de comptage partagé par la
préparation et la réception (le plafond de l'étape précédente est annoncé ET validé avant l'envoi) ;
bouton « Enregistrer en cours » pour une préparation reprise plus tard ; confirmation avant expédition
(« ne s'annule plus ») ; dialogue « Voir les lignes » (demandé / préparé / expédié / reçu).
**Défaut trouvé en relisant les captures et corrigé** : un transfert reçu AVEC ÉCART portait un badge vert
comme un transfert nickel — l'écart est pourtant le fait à remarquer. Badge « Reçue · écart » en ton
d'alerte et mention « le manquant est rentré au dépôt » (2 tests, dont un qui vérifie qu'une réception
complète reste un simple « Reçue »). Captures **32** (liste desktop), **33** (demande mobile),
**34** (préparation mobile), **35** (réception desktop).

**Preuve finale (2026-09-21, après audits)** : backend `lint:check` **0** · **81** unit · **264** e2e
(19 suites, **un seul passage**) dont **15** transferts ; app `flutter analyze` propre · **+227 ~35** dont
**17** transferts · **35** captures produites. Le test « endpoint au contrat figé → 501 » de `auth.e2e-spec.ts` visait
`/api/transfers` : reporté sur `/api/inventories`, encore au contrat.

**Audits P0 #8 (2026-09-21)** — `reviewer` : **MERGE POSSIBLE**, aucun bloquant ; `security-reviewer` :
**NON CONFORME** (0 critique, 1 important, 3 mineurs). Tout ce qui comptait est corrigé :
- **Important (sécurité) : `?status=constructor` rendait 500.** `status in TransferStatus` traverse la
  chaîne de PROTOTYPES : `constructor`, `toString`, `valueOf` passaient la garde (≤ 20 caractères, donc le
  DTO ne les filtrait pas) et atteignaient Prisma comme valeur d'énum → `PrismaClientValidationError`, que
  le filtre HTTP ne sait pas traduire. Liste blanche RÉELLE (`Object.values(...).includes(...)`), et le test
  couvre désormais les trois. **Contre-épreuve : `in` remis → le test échoue** (« Invalid value for argument
  `status` »). Seul endroit du backend qui utilisait ce motif.
- **Mineur généralisé aux RÉCEPTIONS (CONVENTIONS règle 1)** : `POST /receptions` ne bornait pas
  `locationId` au type d'emplacement — un magasinier pouvait réceptionner **dans le TRANSIT**, où le stock
  se serait retrouvé gelé (aucune perte ne s'y déclare). Même garde MAGASIN/DEPOT que le stock initial d'un
  produit et que la déclaration de perte, plus un e2e. Ce n'était pas la P0 #8, mais c'est le même
  invariant : il valait mieux le fermer tout de suite.
- **Chemin UI mort trouvé par la revue** : l'action « Accepter la demande » n'était tapée par AUCUN test
  (le motif exact du bloquant de la P0 #7, en plus petit). Deux tests ajoutés : le dépôt accepte, et une
  demande déjà acceptée ne se ré-accepte pas.
- Exception TRANSIT **resserrée** sur `operationType === 'TRANSFER'` : une future opération sur le transit
  (ajustement d'inventaire de la P0 #9) n'en héritera pas en silence.
- Assertions ajoutées : `sourceLocationId`/`destinationLocationId` du mouvement d'écart (la seule partie non
  éprouvée de ma modification du journal), et emplacement d'une autre espèce → 422 (le sens du flux ne
  s'inverse pas).
- Les deux audits confirment que l'exception TRANSIT est **étanche** : les cinq appelants du journal ont été
  passés en revue, aucun ne peut produire une sortie négative au transit hors d'un transfert.

**Non fait, tracé** : `TransferLine.note` (colonne du schéma Phase 0) n'est alimentée par rien, comme
`ReceptionLine.note` ; le transfert est **en ligne uniquement** (`MutationType.TRANSFER` n'a pas de handler
de synchronisation — c'est la P0 #12) ; pas de bon de transfert PDF (P1 n°21c) ; `TransferListQueryDto.q`
est hérité de la pagination commune et ignoré par la liste (comme sur les réceptions) ; `TransferDto`
n'expose pas `acceptedAt`/`refusedAt`/`cancelledAt`, que le schéma remplit — l'app n'en a pas besoin ;
les états Erreur/Hors-ligne de l'écran et la branche « 409 → on relit la liste » ne sont pas couverts par un
test widget.

**Suite naturelle de l'écart, à trancher par MEDMEDBEN (relevé par la revue, non fait)** : le manquant
rentre au dépôt et y redevient vendable, alors qu'il n'existe peut-être plus — seul le commentaire du
mouvement le dit. Le prolongement sans rien inventer serait de créer, dans la MÊME transaction, une
`StockLossDeclaration` **EN_ATTENTE** au dépôt pour le manquant (mécanisme existant depuis la décision du
2026-09-14 : l'admin valide, le stock part). À faire si tu valides le principe.

**À confirmer par MEDMEDBEN** : l'écart de réception rendu au DÉPÔT (et non laissé en transit) est une
décision que j'ai prise seul faute de règle écrite — dis-moi si tu préfères autre chose.

⚠️ **Piège machine** : l'outil de captures a échoué DEUX fois sur une `FileSystemException` en écrivant
un PNG, puis est repassé vert sans rien changer — un verrou de fichier du poste (explorateur, antivirus),
pas le code. Si ça arrive, relancer avant de chercher un bug.

**Reste à faire (dans l'ordre)**
1. **Relecture humaine des 31 captures** par MEDMEDBEN (seul point qu'aucun agent ne peut faire à sa place).
2. Rejouer le build APK release une fois le NDK Android réinstallé sur le poste.
3. Puis **P0 #8 Transferts magasin↔dépôt**, ensuite #9 Inventaire, #10 Planning, #11 Historique,
   #12 raccordement hors-ligne des opérations (aujourd'hui un seul handler de sync sur douze).
- **Avant production (tracé, non fait)** : NestJS 11 (vulnérabilités `npm audit`), `backend/Dockerfile` + `.dockerignore`,
  MinIO non exposé + utilisateur dédié, signature Android release.
- Autres points de la revue encore ouverts : quantité décimale au panier (vente au mètre), note de commande effacée en
  modification, méthode « VIREMENT » forcée hors caisse, listes app limitées à une page, localisation FR des widgets.

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

✅ **I2 TRANCHÉ ET FAIT (MEDMEDBEN, 2026-09-14) : coût d'achat visible par ADMIN + MAGASINIER.** Nouvelle
permission `cost.read` (seed : 39 permissions — **relancer `npm run seed`**). `ProductsService.forViewer`
renvoie `lastPurchasePriceHt: null` sans `cost.read` et `mainSupplierId: null` sans `supplier.read` (M4), sur
liste, fiche, code-barres ET delta (e2e sur les 4 chemins × 3 rôles + contre-épreuve). App : ces deux champs
ne sont JAMAIS écrits dans la base locale partagée (test) — un futur écran de marge les lira en ligne.
Preuve : backend **60** unitaires · **123** e2e ; app analyze propre · **+164 ~17**. M5 : ajouter `FreshAccessGuard` sur `POST /products/:id/prices` quand la route sortira du 501.
Notes pour plus tard : refuser un changement d'unité si des mouvements de stock existent (feature Stock) ;
la descente devra transporter `ProductPrice` (feature Ventes).

**Contre-audit `security-reviewer` (2026-09-14) : CONFORME** — I1, I2, M1-M4 fermés. 2 mineurs corrigés : les
réponses de création/modification produit passent aussi par `forViewer` ; `npm run seed` ajouté à chaque
déploiement (`docs/DEPLOYMENT.md`). M5 reste à faire avec la feature Ventes (FreshAccessGuard sur les prix).
**Reprise ICI** : relecture humaine des captures 12-17 par MEDMEDBEN → cocher la dernière case de
`docs/plan.md` (P0 n°2) → **P0 #3 (Stock : quantités, mouvements traçables, projection atomique)**.

### ✅ P0 #3 STOCK — 2026-09-15 · **MEDMEDBEN** (fait, audits corrigés ; relecture humaine en attente)
> MEDMEDBEN a dit « continue » après la P0 #2 : la relecture humaine des captures 12-17 reste NON cochée.
- **Décision MEDMEDBEN** : perte du MAGASINIER = EN ATTENTE jusqu'à validation ADMIN (voir `docs/permissions.md`).
- Migration ADDITIVE `stock_loss_declaration` : table `StockLossDeclaration` + enum `StockLossStatus`.
- `src/stock/stock.service.ts` + `stock.controller.ts` (sorti du module contrat) :
  `GET /stock` (paginé, filtres produit/emplacement, stock hors magasin soumis à `stock.read.warehouse`),
  `GET /stock/movements` (journal paginé, filtres type/période), `GET|POST /stock/losses`,
  `POST /stock/losses/:id/validate|reject` (ADMIN, verrou `FOR UPDATE` : deux validations → une seule perte).
  Toute écriture passe par `StockLedgerService` ; audit CREATE/ADJUST/VALIDATE/CANCEL dans la transaction.
- Handler de sync `MANUAL` réécrit sur `StockService.declareLossInTx` (même règle en ligne / hors-ligne) ;
  `test/sync.e2e-spec.ts` exerce le moteur avec un ADMIN + nouveau test « magasinier hors-ligne = EN ATTENTE ».
- `test/stock.e2e-spec.ts` : 13 tests. Contre-épreuves : règle d'attente retirée → échec ; verrou retiré → échec.
Preuve : `tsc` OK · lint propre · **60** unitaires · **137** e2e.
**App — FAITE** : `features/stock/` — `StockScreen` (destination « Stock », `stock.read.store`) : section Niveaux
(magasin · dépôt · transit · total · disponible par produit, badge « Sous le seuil », fiche : niveaux par
emplacement + 50 derniers mouvements) ; section Pertes (ADMIN/MAGASINIER + `stock.loss`) : liste filtrée,
`LossForm` (UUID client v7, quantité décimale en chaîne), Valider / Refuser (confirmation) pour l'ADMIN.
Stock lu EN LIGNE (jamais un chiffre périmé affiché comme vrai). `activeProductsProvider` ajouté au catalogue.
Coquille mobile : au-delà de 4 destinations, le 4ᵉ onglet devient **« Plus »** (§7).
Preuve : `flutter analyze` propre · `flutter test` **+170 ~20**. Captures 18-20 relues par l'agent (1 défaut
corrigé : liste « Où » sans indication) ; scénarios 08/09/11 passés par « Plus ».
**Audits (2026-09-15)** — `reviewer` : PAS OK (2 bloquants) ; `security-reviewer` : NON CONFORME (1 important,
3 mineurs). Tout corrigé et testé :
- bloquant 1 : perte déclarée seulement au MAGASIN ou au DÉPÔT (vérifié serveur, e2e sur un EMPLACEMENT).
- bloquant 2 : renvoi du même formulaire → même déclaration rendue, jamais une seconde perte (id généré UNE
  fois par `LossForm` ; serveur idempotent pour le même déclarant, 409 pour un autre).
- sécu I1 + revue 3 : `FreshAccessGuard` sur déclarer / valider / refuser ET sur `POST /sync` — un admin
  rétrogradé ne valide plus et ses pertes repassent EN ATTENTE, en ligne comme hors-ligne (e2e + contre-épreuve).
- sécu M1 : dates `from`/`to` strictes, date illisible → 400 (plus de 500).
- sécu M2 : journal — le VENDEUR voit le mouvement PERTE_CASSE sans constat ni déclarant.
- sécu M3 + revue 5 : audit `CREATE` en ligne et hors-ligne, avec l'état appliqué (`auditNewValue` du handler).
- revue 4 : `StockService.visibleLocations` testé (unitaire) ; revue 6 : `docs/plan.md` liste la nouvelle table.
- suggestions : tri whitelisté sur mouvements/pertes ; champ `type` inutile retiré du DTO ; limite de la liste
  des pertes notée `ponytail:`. Motif de refus non saisi dans l'app (le serveur l'accepte) — plus tard.
Preuve : backend `tsc` OK · **62** unitaires · **141** e2e ; app analyze propre · **+170 ~20**.
> ⚠️ Docker s'est arrêté pendant la session : relancé, volume `infra_postgres_dev_data` intact.
**Reprise ICI** : relecture humaine des captures 12-20 par MEDMEDBEN (non faite) → cocher `docs/plan.md` →
P0 #4 (Ventes : tarifs, TVA/ticket/facture, caisse, dettes clients). Rappel : réservation de stock à trancher.

### 🧩 Retours MEDMEDBEN sur la fiche produit (2026-09-15) — en cours
Demandé : fournisseur sur la fiche, photo du produit, quantité à la saisie, état du stock (en stock / peu / fini).
- **Fournisseur** : DÉJÀ PRÉVU — feature **P0 #5**. `Product.mainSupplierId` existe côté serveur ; à la P0 #5,
  ajouter le choix du fournisseur dans `ProductForm` (liste des fournisseurs, masquée sans `supplier.read`).
- ✅ **Quantité à la saisie** : `CreateProductDto.initialStock` (magasin et/ou dépôt, 2 max) → un mouvement
  `AJUSTEMENT_INVENTAIRE` par lieu (operationType PRODUCT) via `StockLedgerService`, dans la transaction de la
  création, tracé dans l'audit. Refus : lieu ≠ MAGASIN/DEPOT, négatif, lieu répété (atomique : rien créé).
  App : champs « Stock au magasin / au dépôt » à la création seulement.
- ✅ **État du stock** : `stock/presentation/stock_status.dart` — Rupture (≤ 0), Stock faible (≤ seuil
  minimum), En stock — colonne « Stock » du catalogue (desktop + mobile), fiche produit, écran Stock.
  Lu en ligne ; sans droit ou hors ligne, rien n'est affirmé.
- ✅ **Photo du produit** : `src/storage/` (MinIO, bucket PRIVÉ, config validée au démarrage : `MINIO_*` dans
  `backend/.env`) ; `POST|DELETE /products/:id/image` (ADMIN + product.write, 2 Mo, type vérifié sur les OCTETS —
  JPEG/PNG/WebP), `GET /products/:id/image` (3 rôles, authentifié, `nosniff`), clé versionnée `imageKey`, audit,
  aucun objet orphelin. App : `image_picker` + `image` (JPEG ≤ 1024 px avant envoi), section Photo du formulaire,
  vignette à la demande (`productImageProvider`, jamais préchargée) dans la liste mobile.
  ⚠️ Image MinIO passée sur `quay.io/minio/minio` (Docker Hub refuse désormais `minio/minio`).
  Preuve : backend **65** unitaires · **147** e2e (photo ×4 sur le vrai MinIO) ; app analyze propre · **+173 ~20**
  (dont un vrai bug trouvé : fichier corrompu → plantage du décodeur, désormais refusé).
**Reprise ICI** : relecture humaine des captures (12-20 + fiche produit avec photo/stock initial) → P0 #4 Ventes.
Preuve : backend **62** unitaires · **143** e2e (stock initial ×2) ; app analyze propre · **+171 ~20**.

### 🚧 P0 #4 VENTES — EN COURS (2026-09-15 · **MEDMEDBEN**)
**Décisions MEDMEDBEN (2026-09-15)** :
- **Pas de réservation de stock en P0** : vente validée = sortie de stock immédiate (`reservedQuantity` reste
  à 0 ; réservation plus tard pour commandes client / devis).
- **N° de facture** : `FA-AAAA-NNNNNN` (ex. `FA-2026-000001`), compteur remis à 1 chaque 1er janvier,
  attribué serveur en transaction (`InvoiceCounter` FACTURE × année).
- **Paiement : ESPÈCES uniquement** (+ vente à crédit dans le plafond du client). Chèque/virement/carte : non.
Découpage (chaque tranche testée + poussée) :
1. ✅ **Prix par tarif** — `POST /products/:id/prices` (ADMIN + price.manage + `FreshAccessGuard`, borne 2 Md
   centimes, audit `ProductPrice` avant/après), `prices` dans chaque produit et dans le delta (produit « touché »).
   App : prix par tarif dans le formulaire (ADMIN), lecture seule pour les autres. Preuve : backend 41 e2e
   catalogue ; app **+175 ~20**.
2. ✅ **Caisse (backend)** — `src/sales/cash-sessions.*` : ouvrir au MAGASIN (1 caisse ouverte par compte, verrou),
   `GET /cash-sessions/current` (corps vide si aucune), clôture = rapport Z (attendu = fond + ventes espèces +
   entrées − sorties ; écart), rapport : le vendeur sa session, l'admin toutes (404 pour autrui). 4 e2e.
3. ✅ **Vente (backend)** — `src/sales/sales.service.ts` : `POST /sales` au MAGASIN, prix NON envoyé par le client
   (tarif du client ou défaut, figé), TVA figée, arrondi au centime demi-haut, remise ADMIN seule, espèces →
   caisse ouverte du vendeur (`CashMovement VENTE_ESPECES`), reste = crédit (client + `sale.credit` + plafond sous
   verrou client), ticket `TK-AAAA-NNNNNN` (séquence `sale_ticket_seq`, migration additive), mouvements VENTE via
   le journal, UNE transaction, idempotent sur l'id client. `GET /sales` (vendeur : les siennes), `GET /sales/:id`.
   Annulation ADMIN : retours stock (RETOUR_CLIENT), sortie de caisse, ANNULEE, audit ; refus si facturée, réglée
   ou caisse clôturée. Ventes normales NON auditées (spec §24).
4. ✅ **Facture (numéro)** — `POST /sales/:id/invoice` : `FA-AAAA-NNNNNN` via `InvoiceCounter` (UPDATE … RETURNING
   sous verrou de ligne, année Africa/Algiers), idempotent, audit VALIDATE. ⏳ **PDF** : moteur unique à choisir.
   Preuve : 19 e2e ventes (stock insuffisant atomique, dernière unité en concurrence, crédit concurrent — contre-
   épreuve verrou retiré → échec —, 5 facturations simultanées consécutives…). Backend **65** unit · **171** e2e.
5. ✅ **Clients + règlements (backend)** — `src/customers/` : liste (recherche nom/téléphone/code) et fiche avec
   dette recalculée, création/modif par ADMIN+VENDEUR, **tarif et plafond : ADMIN seul** (403 sinon, audité) ;
   `POST /payments/customer` : espèces dans la caisse OUVERTE (`CashMovement ENTREE`), jamais au-delà de la dette
   ni du reste dû de la vente visée, verrou client, audit. Fournisseurs et paiement fournisseur restent 501 (P0 #5).
   4 e2e. Backend **65** unit · **175** e2e.
6. ✅ **App** — `features/sales/` : destination « Vente » (ADMIN/VENDEUR + sale.create) ; barre de caisse (ouvrir avec
   fond, clôturer → rapport Z) ; panier (douchette = saisie + Entrée, recherche, +/−, retirer) avec UUID de vente
   stable (renvoi idempotent) ; client facultatif (recherche, dette, plafond) ; estimation HT/TVA/TTC avec les
   MÊMES règles et arrondi que le serveur (testé sur la référence e2e) ; encaissement : espèces reçues → gardé ≤
   total, reste = crédit, monnaie à rendre ; ticket + « Émettre la facture » ; section Clients (création, dette,
   règlement espèces). Le client n'envoie jamais de prix. Preuve : app **+178 ~20**.
7. ✅ **Audits P0 #4** — `security-reviewer` (commit 12b890a : caisse verrouillée `FOR UPDATE` pendant encaissement/
   annulation/règlement, règlement idempotent, droits relus en base, total borné, verrous triés, tarif inactif) puis
   `reviewer` : `expectedTotalTtc` (409 si le total serveur ≠ total affiché — l'app recharge le catalogue), renvoi
   du même id avec un autre panier → 409, annulation refusée si elle rendrait la dette négative (acompte général),
   rapport Z avec entrées/sorties, spec §ventes alignée (FA-AAAA-NNNNNN, ventes non auditées), 5 e2e ajoutés
   (caisse clôturée, règlement rattaché, acompte général, total changé, panier modifié).
   Preuve : backend **65** unit · **183** e2e (`--runInBand`) ; app analyze propre, **+178 ~20**.
8. ✅ **PDF** — moteur UNIQUE `pdfkit` (`backend/src/common/pdf/pdf.ts` : `renderPdf`, `formatDA`, heure d'Alger ;
   polices standard, rien à embarquer dans Docker). `GET /sales/:id/pdf` : **facture A4** si numéro légal (vendeur,
   NIF/RC/NIS/AI, client, lignes PU HT/TVA/total HT, TVA ventilée par taux, TTC, payé/reste, « VENTE ANNULÉE »), sinon
   **ticket 80 mm** ; mêmes droits que le détail (vendeur : ses ventes, 404 sinon). Identité du magasin : variables
   `STORE_NAME/ADDRESS/PHONE/NIF/RC/NIS/AI` (backend/.env.example, infra/.env.example — **à renseigner avant la mise
   en service**). App : bouton « Imprimer le ticket / la facture » (paquet `printing` : impression, « Enregistrer en
   PDF », partage mobile) ; total HT estimé affiché sur chaque ligne du panier. Rendus relus (ticket + facture annulée).
   Captures **21** vente desktop, **22** vente mobile, **23** clients mobile. Preuve : backend **68** unit · **184** e2e ;
   app analyze propre, **+178 ~23**.
   Non fait (volontairement) : archivage des factures dans MinIO (spec : « peuvent », à la demande), montant en
   lettres sur la facture (à confirmer si exigé).
9. ✅ **Contre-audits** — `security-reviewer` **CONFORME** (4 mineurs) · `reviewer` **PAS OK** (1 bloquant) → tout corrigé :
   - **Facture datée du jour de FACTURATION** : colonne `Sale.invoicedAt` (migration ADDITIVE
     `20260915200731_sale_invoiced_at`, anciennes factures remplies avec `soldAt`), imprimée comme date ; le ticket
     d'origine et sa date restent mentionnés. Sinon un ticket du 31/12 facturé le 02/01 portait `FA-2027-…` daté 2026.
   - Annulation : **verrou client** avant le calcul de dette (acompte simultané ne peut plus rendre la dette négative).
   - Renvoi du même id : panier comparé en multi-ensemble (doublons, remises, client) ; code dédié
     `SALE_ALREADY_RECORDED` avec n° et montant de la vente existante → l'app **vide le panier (nouvel id)** au lieu
     de renvoyer en boucle ; `SALE_TOTAL_CHANGED` (montant en DA, plus en centimes).
   - PDF : **facture refusée (422 `STORE_IDENTITY_MISSING`) sans `STORE_NIF` et `STORE_RC`** (le ticket reste
     imprimable) ; hauteur du rouleau selon la longueur des désignations (test unitaire : 200 lignes × 150 car. = 1 page,
     contre-éprouvé) ; PU TTC en Decimal ; PDF bridé à 30/min ; erreur d'impression locale affichée.
   - Docs : exemple `FAC-` retiré de la spec, CONVENTIONS sans « templates HTML ».
   Preuve : backend **72** unit · **184** e2e (`--runInBand`) ; app analyze propre, **+179 ~23** (test « vente déjà
   enregistrée » contre-éprouvé).
   ⚠️ Piège : `npm run lint` fait `--fix` et reformate ~40 fichiers anciens (fins de ligne / prettier) — ne pas les
   committer avec une feature. Les stubs 501 (`_dto` inutilisés) font toujours échouer `lint` : disparaîtront avec leurs features.
10. ⏳ Relecture humaine (captures 21-23, PDF ticket/facture) → **P0 #5 Fournisseurs** (+ fournisseur dans la fiche
   produit, demandé par MEDMEDBEN). À confirmer par MEDMEDBEN : montant en lettres et NIF client sur la facture, mention
   « DUPLICATA » à la réimpression, police arabe (Helvetica n'affiche pas l'arabe).
Hors-ligne des ventes : feature P0 #12 (prérequis N6b).

### 🚧 P0 #5 FOURNISSEURS — EN COURS (2026-09-16 · **MEDMEDBEN**)
**Décisions MEDMEDBEN (2026-09-16)** :
- **Dette fournisseur = reprise de l'existant** : l'admin saisit `Supplier.openingBalance` (ce qui était déjà dû
  avant le logiciel) ; dette = reprise − paiements, les achats (P0 #6) s'y ajouteront. Pas de facture fournisseur
  ligne à ligne en P0 #5 (ce serait la feature Achats faite deux fois).
- **Paiement fournisseur : au choix** — `fromCash: true` → SORTIE de la caisse OUVERTE (rapport Z) ;
  `fromCash: false` → hors caisse (virement, espèces hors tiroir), la caisse n'est pas touchée.
1. ✅ **Backend** — migrations ADDITIVES `supplier_opening_balance` et `supplier_payment_cash_session`
   (`SupplierPayment.cashSessionId` : d'où l'argent est sorti). `src/suppliers/` : liste paginée + recherche
   (nom/téléphone/code, inactifs masqués), fiche, création/modif ADMIN (`FreshAccessGuard`, auditées),
   `POST /payments/supplier` (jamais au-delà du reste dû, verrou fournisseur, idempotent sur l'id, audit).
   La reprise ne peut pas descendre sous ce qui est déjà payé. **Vendeur : aucun accès** (rôle). Stubs 501
   fournisseurs supprimés (`parties.controller.ts`, `SupplierPaymentsController` des ventes) ; `booleanQuery`
   factorisé dans `common/validation.ts`. Preuve : **72** unit · **195** e2e (11 fournisseurs).
2. ✅ **App** — `features/suppliers/` : destination « Fournisseurs » (ADMIN|MAGASINIER + `supplier.read`),
   recherche, dette par fiche, formulaire (reprise de dette, admin), paiement avec bascule « payé depuis la
   caisse » et id stable (renvoi sans double paiement) ; **fournisseur principal dans la fiche produit**
   (demandé par MEDMEDBEN) affiché seulement avec `supplier.read`. Captures **24** (desktop) et **25**
   (paiement mobile). Preuve : analyze propre, **+184 ~25**.
3. ✅ **Audits P0 #5** — `security-reviewer` **CONFORME** (4 mineurs) · `reviewer` **PAS OK** (1 bloquant) → corrigés :
   - **Bloquant : la caisse pouvait passer en négatif.** Un paiement en espèces est désormais borné par ce que le
     tiroir contient (`CASH_INSUFFICIENT`) — contre-éprouvé : garde retirée → le test échoue.
   - Renvoi d'un paiement avec un AUTRE montant → 409 `PAYMENT_ALREADY_RECORDED` (fournisseurs ET règlements clients).
   - Audit : `email` et `notes` tracés (fournisseurs et clients) — une modification d'email ne passait pas au journal.
   - Liste fournisseurs : un seul `groupBy` au lieu d'un agrégat par ligne (N+1) ; champs texte trimés ;
     `supplierSearchProvider` lié au compte connecté ; droits d'écriture de l'app alignés sur le guard (rôle + permission).
   - Checklist P0 #5 ajoutée à `docs/plan.md`.
   Reste noté pour P0 #6 (Achats) : correction/annulation d'un paiement fournisseur (règle 7), historique des
   paiements consultable, tri `?sort=` figé sur les listes clients/fournisseurs.
   Preuve : backend **72** unit · **197** e2e ; app analyze propre, **+184 ~25**.
4. ⏳ Relecture humaine (captures 24-25).

### 🚧 P0 #6 ACHATS — CODE LIVRÉ, RELECTURE HUMAINE EN ATTENTE (2026-09-16 · **MEDMEDBEN**)
**Décisions MEDMEDBEN (2026-09-16)** :
- **La dette fournisseur augmente à la RÉCEPTION** (quantités réellement reçues), pas à la commande.
  Conséquence pour P0 #7 : `SuppliersService.debt` devra ajouter Σ(lignes reçues × prix) à `openingBalance`.
- **Surlivraison REFUSÉE** : on ne réceptionne jamais plus que le reste à recevoir d'une ligne de commande
  (le magasinier fait d'abord modifier la commande).
1. ✅ **Backend commandes** — `src/purchases/purchase-orders.{service,controller}.ts`, `dto/purchase-order.dto.ts`,
   `purchases.module.ts` (déclaré dans `app.module.ts`, stub 501 des commandes retiré du contrat ; les réceptions
   restent en 501). Numéro `BC-AAAA-NNNNN` par `common/document-number.ts` (**générateur unique**, `sales.service.ts`
   l'utilise désormais aussi pour `FA-`). Création ADMIN+MAGASINIER (BROUILLON, idempotente sur l'id, fournisseur et
   produits actifs exigés, quantité > 0, prix et TVA figés, totaux bornés), `PATCH` tant que BROUILLON/COMMANDEE
   (lignes remplacées), `confirm` ADMIN (idempotent, verrou de ligne), `cancel` ADMIN (refus si réception existe),
   liste filtrée (statut, fournisseur) + détail avec reste à recevoir. Tout audité.
   Preuve : **9 e2e** `test/purchase-orders.e2e-spec.ts`. L'exemple « 501 » de `auth.e2e-spec.ts` vise désormais
   `/api/receptions` (commandes implémentées).
2. ✅ **App** — `features/purchases/` : destination « Achats » (ADMIN|MAGASINIER + `purchase.create`), liste avec
   statut, formulaire (fournisseur, lignes produit/quantité/prix d'achat HT, total estimé, id stable), actions
   « marquer envoyée », « confirmer » et « annuler » (ADMIN seul, confirmation demandée), consultation des lignes
   (reçu / reste) une fois confirmée. Captures **26** (liste) et **27** (nouvelle commande). 5 tests widget.
   Preuve (2026-09-16) : backend **72** unit · **206** e2e (`--runInBand`) ; app analyze propre, **+189 ~27**.
   ⚠️ Piège machine : Docker Desktop était arrêté → e2e tous en échec (`AggregateError`). Le relancer d'abord.
3. ✅ **Audits P0 #6** — `security-reviewer` **NON CONFORME** (2 importants, 3 mineurs) · `reviewer` **PAS OK**
   (5 points) → corrigés :
   - **L'admin ne confirme que la version qu'il a vue** : `POST /purchase-orders/:id/confirm` exige
     `expectedUpdatedAt` ; commande modifiée entre-temps → 409 (contre-éprouvé). L'app envoie l'`updatedAt` affiché.
   - **Audit de modification complet** : lignes (produit, quantité, prix, TVA), dates et note avant/après — un échange
     de prix à total égal reste visible.
   - Dates strictes : `common/api-date.ts` (`parseApiDate`, utilisé aussi par le journal de stock) — `2026-W05` ou
     `2026-02-30` → 400, plus jamais 500 ni date fausse.
   - Transition unique BROUILLON → COMMANDEE (retour en brouillon refusé) ; modification refusée dès qu'une
     réception existe (les lignes ne sont jamais effacées sous une réception) ; renvoi du même id avec un autre
     contenu → 409 ; note trimée en modification ; « Annuler » n'est plus proposé sur une commande en cours de réception.
   - Tests ajoutés : version périmée, audit des prix, transitions refusées, réception existante, renvoi modifié,
     dates, arrondi demi-haut par ligne.
   Preuve : backend **79** unit · **212** e2e (`--runInBand`) ; app analyze propre, **+189 ~27**.
   Dette notée : `MAX_MONEY` à déplacer dans `common/` ; liste des commandes limitée à 200 sans pagination.
4. ⏳ Relecture humaine (captures 26-27) → **P0 #7 Réceptions** (stock +, `lastPurchasePriceHt`, dette fournisseur =
   reprise + Σ reçu × prix − paiements, statuts PARTIELLEMENT_RECUE/RECUE, surlivraison refusée).
   **Obligatoire en P0 #7** (audit sécu) : la création d'une réception prend le MÊME `SELECT … FOR UPDATE` sur
   `PurchaseOrder` que `cancel`/`update`, refuse ANNULEE (et réceptionne seulement une commande CONFIRMEE ou
   PARTIELLEMENT_RECUE), avec un test e2e annulation ↔ réception simultanées.

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
- **`DATABASE_URL` est câblé à DEUX endroits** : `prisma.config.ts` = **CLI**,
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
| Produits + catégories + emplacements | 🟡 **~95 %** — relecture humaine des écrans | 🟡 Contrat figé (501) | — | — | — |
| Stock + mouvements | 🟡 **~95 %** — relecture humaine | 🟢 Lecture, journal, pertes + validation | 🟢 Niveaux, pertes, « Plus » mobile | 🟢 141 e2e · 170 app | 🟢 corrigé |
| Ventes (tarifs, TVA/facture, caisse) + dettes clients | 🟡 **Code livré**, relecture humaine en attente | 🟢 Panier, TVA, ticket/facture PDF, caisse, crédit + échéance | 🟢 Vente, caisse, rapport Z, clients | 🟢 e2e + widget | 🟢 CONFORME |
| Fournisseurs + clients + dettes fournisseurs | 🟡 **Code livré**, relecture humaine en attente | 🟢 Fiches, reprise de dette, paiements, contre-passation | 🟢 Fournisseurs, clients, historiques | 🟢 e2e + widget | 🟢 CONFORME |
| Achats | 🟡 **Code livré**, relecture humaine en attente | 🟢 Commandes, statuts, confirmation ADMIN, annulation | 🟢 Liste, formulaire, actions | 🟢 15 e2e · 5 widget | 🟢 corrigé |
| Réceptions (dont partielles) | 🟡 **Code livré**, relecture humaine en attente | 🟢 Partielles, surlivraison refusée, dette | 🟢 Réception depuis la commande | 🟢 11 e2e · 6 widget | 🟢 corrigé (2 importants) |
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
