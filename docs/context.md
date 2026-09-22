# Décisions d'architecture

## Stack
- **Flutter unique (desktop + mobile)** : évite de coder deux fois la logique métier. Un seul dev peut couvrir les deux plateformes.
- **PostgreSQL (pas de NoSQL)** : le métier exige des transactions ACID strictes (stock, ventes, dettes) — non négociable.
- **NestJS + Prisma** : structure modulaire alignée sur le découpage métier ; Prisma élimine le risque d'injection SQL par défaut.
- **Drift (SQLite local)** : offline-first sur mobile et desktop, moteur de sync par mutations en file d'attente.

## Déploiement
- Backend sur VPS externe (pas de serveur local au magasin).
- Desktop : 1 seul poste, connexion/déconnexion tolérée.
- Mobile : les 3 rôles, mais chaque rôle ne synchronise que le sous-ensemble de données utile à son travail (voir `docs/plan.md`).

## Rôles (figés) — 3 rôles
Admin · Vendeur/Caissier · Magasinier. Un membre peut cumuler des permissions accordées par l'admin. (Décision du 2026-09-08 — voir journal.)

## Décisions métier figées (2026-09-08)
- **Coût produit = dernier prix d'achat** (marge = prix vente − dernier prix réceptionné).
- **Montants en entiers (centimes de DA)** partout — jamais de float.
- **Stock** : `StockMovement` = source de vérité (deltas additifs) ; `Stock.quantity` = projection recalculée dans la même transaction.
- **Offline** : périmètre large dès le départ, **ventes hors-ligne incluses** — donc la validation anti-survente au sync est critique (voir Contrat de synchronisation ci-dessous).

---

# Contrat de synchronisation offline (NON NÉGOCIABLE)

Ce contrat s'applique à toute opération créée sur un appareil (desktop ou mobile) pouvant être hors connexion. Il doit être implémenté en Phase 0 (au moins le socle) avant toute feature offline.

## 1. Identifiants
- **Toute entité créable hors-ligne reçoit un `id` UUID généré côté client** (UUIDv7 recommandé : trié dans le temps, pas de collision, pas d'attente du serveur). Pas d'auto-increment comme clé primaire pour ces entités.
- Le serveur accepte l'`id` fourni par le client (il ne le régénère pas).

## 2. File de mutations
- Chaque opération hors-ligne est enregistrée localement (Drift) dans une **file de mutations** : `client_mutation_id` (UUID unique), type d'opération, payload, timestamp appareil, `device_id`, statut local (`en_attente` / `confirmée` / `rejetée`).
- La file est envoyée au serveur dans l'ordre du timestamp appareil, par lots, dès reconnexion.

## 3. Idempotence
- Le endpoint de sync (`POST /sync` ou par ressource) est **idempotent** : le serveur mémorise les `client_mutation_id` déjà traités. Un renvoi (reconnexion instable, retry) **ne réapplique pas** la mutation — il renvoie le résultat déjà calculé.
- Conséquence : un mouvement de stock n'est jamais appliqué deux fois.

## 4. Application et validation serveur
Pour chaque mutation, le serveur, dans une transaction :
1. Vérifie le `client_mutation_id` (déjà vu → renvoie l'ancien résultat, stop).
2. Vérifie les **permissions** du user (comme en ligne).
3. Applique la règle métier et **valide** :
   - **Anti-stock-négatif** : si l'opération rend le stock disponible < 0 → **REJET** (sauf produit « backorder autorisé »).
   - Autres invariants métier (produit actif, montants cohérents, etc.).
4. Si OK : applique le(s) mouvement(s) additif(s) + met à jour les projections + écrit l'audit. Renvoie `confirmée` + l'état serveur.
5. Si rejet : n'applique rien, renvoie `rejetée` + un motif lisible.

## 5. Résolution des divergences
- **Stock** : les mouvements étant additifs, deux mutations concurrentes de deux appareils **s'appliquent toutes les deux** (sous réserve de validation § 4). Pas de « dernier gagnant » sur les quantités.
- **Champs absolus** (ex : prix d'un produit, fiche client) : « dernier écrivain gagne » au niveau du champ, basé sur le timestamp serveur. Ces éditions ne sont normalement pas faites hors-ligne par plusieurs personnes.

## 6. Côté UI (obligatoire)
- Une opération non confirmée par le serveur s'affiche avec un état **`⟳ en attente de synchronisation`** — jamais comme définitive.
- Une opération **rejetée** au sync s'affiche clairement comme **échouée**, avec le motif, et exige une action de l'utilisateur : annuler, ou corriger et re-soumettre (ex : vente rejetée pour stock insuffisant → proposer de réduire la quantité ou d'annuler la vente).
- États UI à prévoir sur chaque écran concerné : `Loading`, `Empty`, `Error`, `Success`, `Offline`, `Sync en attente`.

## 7. Cas particulier — vente hors-ligne
La vente hors-ligne est autorisée (décision produit), mais :
- Le stock affiché hors-ligne peut être périmé → la validation § 4 au sync fait autorité.
- **Prix (décision MEDMEDBEN 2026-09-22)** : l'appareil envoie le prix APPLIQUÉ de chaque ligne (tarif, ou prix
  modifié par le vendeur) ; le serveur l'accepte s'il n'est pas sous le plancher (dernier prix d'achat, sinon tarif)
  — un tarif changé pendant la coupure ne fait donc plus rejeter la vente. Le total encaissé (`expectedTotalTtc`,
  obligatoire hors-ligne) reste comparé : seul un changement de TVA pendant la coupure peut encore le faire
  diverger (`SALE_TOTAL_CHANGED`). Cas limite accepté : produit SANS coût connu dont le tarif a été relevé pendant
  la coupure → l'ancien prix peut passer sous le plancher (le plus bas tarif), vente refusée et tracée. En
  ligne, un prix NON modifié par le vendeur doit être le tarif courant (sinon 409 : catalogue local en retard) ;
  une ligne modifiée porte `priceEdited` et c'est elle seule qui est tracée pour l'admin.
- Une vente hors-ligne est un **TICKET**, datée de l'appareil si l'instant est plausible (ni futur, ni
  plus de 72 h), sinon de sa synchronisation. Ses espèces portent la **caisse de la vente**
  (`cashSessionId`, obligatoire hors-ligne) : si ce n'est plus la caisse ouverte du vendeur au sync, REJET
  `CASH_SESSION_CLOSED` — jamais d'imputation à une autre caisse, et aucune horloge d'appareil en jeu. Tant
  que la file du compte n'est pas vide, l'app clôture la caisse PAR LA FILE, derrière les ventes (§8). Une vente **à crédit** n'a pas de
  caisse pour la borner : un appel direct à /sync peut l'antidater jusqu'à 72 h (risque accepté, à confirmer).
- Tout rejet de sync (hors refus d'accès) est tracé dans l'Historique (`AuditLog` `REJECT`) : une vente
  refusée a pu avoir lieu physiquement.
- La dette client est (re)calculée **côté serveur** au moment de l'application, jamais figée par le client.

## 8. Caisse hors-ligne (P0 #12 tranche C, 2026-09-22)
- Opération `CASH_SESSION` : payload = le corps de la route en ligne + `action` (`OPEN` | `CLOSE`) ; une
  clôture porte `sessionId`. Même cœur que `POST /cash-sessions` et `…/:id/close`, mêmes droits.
- L'**id de la caisse est généré par l'appareil** (contrat §1) : les ventes hors-ligne la désignent
  (`cashSessionId`) avant qu'elle n'existe au serveur. L'ordre de la file (appareil) impose ouverture →
  ventes → clôture ; une vente en ligne dont la caisse est encore en file passe elle aussi par la file.
- Caisse ouverte / clôturée datée de l'appareil (même borne plausible que la vente) : le rapport Z garde
  une chronologie cohérente avec ses ventes.
- Côté app, l'état de caisse = la dernière ouverture/clôture EN FILE, sinon le dernier état lu au serveur
  (conservé sur l'appareil, même après redémarrage). Jamais connu hors ligne → aucune ouverture proposée :
  une caisse déjà ouverte au serveur ferait refuser toutes les ventes de la journée.
- Rejets possibles : caisse déjà ouverte (`CASH_SESSION_ALREADY_OPEN`), clôture d'une caisse d'autrui
  (introuvable) ou déjà clôturée — tous tracés dans l'Historique.

## 9. Transferts et règlements clients hors-ligne (P0 #12 tranche E, 2026-09-22)
- **Règlement client** (`CUSTOMER_PAYMENT`) : corps de `POST /payments/customer` + `cashSessionId`
  OBLIGATOIRE (mêmes règles que la vente en espèces) ; dette et reste dû rejugés AU SYNC ; relu sous le verrou
  du client (un règlement déjà fait en ligne est reconnu, jamais refusé comme « supérieur à la dette »).
- **Transfert** (`TRANSFER`) : une étape par mutation, champ `action` (`REQUEST` = corps de la demande ;
  `ACCEPT`/`SHIP` sans corps ; `PREPARE`/`RECEIVE`/`CLOSE` = corps de leur route) + `transferId`. Droits
  contrôlés PAR ÉTAPE, identiques aux routes. Une étape dont l'état cible est déjà atteint (faite en ligne,
  réponse perdue) est reconnue sous le verrou du transfert. Une étape ne passe jamais devant une étape de
  transfert encore en file sur l'appareil.
- **Comptage d'inventaire : reste EN LIGNE** (décision d'implémentation après audit, 2026-09-22). Un comptage
  mis en file serait comparé à un théorique que le serveur ne sait pas dater : relu au sync, les mouvements
  survenus entre-temps créent un écart fantôme ; relu « à l'heure de l'appareil », l'heure est falsifiable
  (masquer un vol) et les mouvements hors-ligne du même appareil portent l'heure de leur synchro (écart
  fantôme appliqué deux fois à la validation). Hors-ligne propre = horodatage d'opération sur chaque
  mouvement + contrôle par l'admin : à décider avec l'inventaire mobile (P1 n°14).
- Une étape de transfert « déjà faite » n'est reconnue que si elle l'a été par le MÊME membre (réponse perdue) ;
  faite par un autre, elle est REFUSÉE (tracée). Une PRÉPARATION se réapplique tant que le transfert est
  préparable (correction). Une CLÔTURE n'est jamais reconnue (le transfert ne garde pas qui l'a close) : déjà
  close, elle est refusée ; la règle auteur/dépôt est vérifiée avant.
- Les dates d'étape d'un transfert (acceptation, expédition, réception, refus) sont celles de la SYNCHRO,
  comme ses mouvements de stock. Une étape ne passe jamais devant une étape de transfert encore en file sur
  l'appareil (prudent : une seule étape bloquée en file fait passer toutes les suivantes par la file).
- Tout refus levé pendant l'application d'une mutation est audité (`REJECT`), refus de droits MÉTIER compris
  (vente à crédit sans `sale.credit`, réception hors commande) ; seuls les refus d'accès du moteur (rôle et
  permission de l'opération) ne le sont pas.

---

# Bornes de données offline (mobile & desktop)

Pour éviter un SQLite local qui gonfle et un stock trop périmé, la synchronisation locale est **bornée** :

- **Catalogue** : produits + catégories + emplacements complets en local (texte léger). **Images en lazy-load** et cache à la demande (jamais préchargées en masse), compressées à l'upload.
- **Historique borné dans le temps** : ventes, mouvements, réceptions, transferts des **30 derniers jours** en local (constante configurable `LOCAL_HISTORY_DAYS`). Au-delà : consultable uniquement en ligne.
- **Sous-ensemble par rôle** (voir `docs/plan.md`) : chaque appareil ne télécharge que ce qui sert à son rôle.
- **Purge locale** : les données synchronisées plus vieilles que `LOCAL_HISTORY_DAYS` sont purgées du local.
- **Plafond de file de mutations** : au-delà de `MAX_PENDING_MUTATIONS` (ex : 200) ou de `MAX_OFFLINE_HOURS` (ex : 72 h) sans sync, l'app **alerte** l'utilisateur et **restreint** les nouvelles opérations sensibles (surtout ventes) — un appareil trop longtemps hors-ligne travaille sur un stock trop faux.
- **Premier lancement** : téléchargement initial du sous-ensemble du rôle ; ensuite **delta sync** uniquement (curseur / timestamp serveur).

# Mobile — optimisations attendues

En plus de l'UX mobile de `docs/spec-fonctionnelle.md` (une action par écran, pas de tableaux desktop) :

- **Pagination systématique** de toutes les listes (jamais de « tout charger »).
- **Lecture cache-first** : afficher immédiatement le local, puis rafraîchir en arrière-plan.
- **Delta sync** seulement (pas de re-téléchargement complet).
- **Images** : compression + redimensionnement avant upload (photos réception/problème) ; miniatures en liste, pleine résolution à la demande.
- **Payloads légers** : endpoints mobiles renvoient le strict nécessaire (pas d'objets imbriqués inutiles).
- **Scanner** : résultat instantané depuis le cache local si le produit y est.
- **Indicateur de sync** visible en permanence (`✓` / `⟳` / nombre d'opérations en attente).
- **Répartition des features** : le mobile expose les opérations terrain (vente, scan, réception, préparation, inventaire, transfert, demandes, notifications, planning) ; la configuration lourde, les grandes listes et les rapports détaillés restent **desktop**.

# Journal des décisions

- **2026-09-08** — Rôles figés à 3 (Admin, Vendeur/Caissier, Magasinier), un membre peut cumuler. Raison : correspond au besoin réel « petite équipe » du Cahier fonctionnel ; « Responsable » et « Lecture seule » écartés pour éviter une matrice de permissions inutilement large au MVP.
- **2026-09-08** — Coût = dernier prix d'achat (et non CUMP). Raison : suffisant pour le MVP, simple à implémenter ; migration vers CUMP possible plus tard sans casser le modèle (les prix unitaires historiques sont conservés sur les lignes).
- **2026-09-08** — Offline large incluant les ventes. Raison : besoin terrain ; conséquence assumée = validation anti-survente stricte au sync (§4) + UX de réconciliation des rejets (§6).
- **2026-09-08** — `Cahier_Fonctionnel` promu source de vérité fonctionnelle, consolidé dans `docs/spec-fonctionnelle.md` ; fichiers racine archivés.
- **2026-09-09** — Quantités décimales (produits vendus au mètre) : type `Decimal`, `unit` par produit. Impact schéma sur toutes les lignes/quantités.
- **2026-09-09** — TVA + ticket/facture : taux de TVA par produit ; vente de type `TICKET` (défaut) ou `FACTURE` (numéro légal séquentiel serveur, en ligne uniquement). Raison : clients particuliers (ticket) et pros (facture).
- **2026-09-09** — Multi-tarifs (détail/gros) via `PriceTier` + `ProductPrice` ; le client porte un tarif par défaut ; prix figé sur la `SaleLine`. Raison : matériel électrique vendu au détail et en gros.
- **2026-09-09** — Caisse avec clôture quotidienne : `CashSession` + `CashMovement`, rapport Z. Encaissement espèces rattaché à une session ouverte.
- **2026-09-09** — Bornes offline et optimisations mobiles définies (voir sections ci-dessus).
- **2026-09-09** — Prix & tarifs gérés par l'admin uniquement ; le vendeur les voit/applique, pas de remise libre.
  **Amendé le 2026-09-22 (MEDMEDBEN)** : le prix d'une ligne est modifiable en vente (vendeur + admin), jamais sous le
  dernier prix d'achat (sans coût connu : jamais sous le plus bas de ses tarifs — provisoire, à revoir plus tard ; ni coût ni tarif : pas de vente tant que l'admin n'a pas fixé un prix — validé par MEDMEDBEN le 2026-09-22), tarif et prix appliqué gardés sur la ligne, vente à
  prix modifié tracée dans l'Historique. Raison : supprime le rejet « prix changé pendant la coupure » — le prix vu
  par le client fait foi.
- **2026-09-09** — Vente à crédit autorisée au vendeur dans la limite du client fixée par l'admin.
- **2026-09-09** — Commandes fournisseurs créables par l'admin ET le magasinier (confirmation = admin).
- **2026-09-09** — Ajout génération de fichiers : PDF (ticket, facture, devis, bons de livraison/transfert/commande, rapports) + exports Excel/CSV d'historique ; import Excel/CSV (produits, clients, fournisseurs, stock initial). Une seule bibliothèque par besoin (voir `CONVENTIONS.md`).
- **2026-09-09** — Codes-barres : capture du code fabricant si présent, sinon génération interne unique (séquence + contrainte d'unicité) ; étiquettes imprimables (nom/prix/code-barres) en planche A4 et thermique.
- **2026-09-09** — Devis (`Quote`) ajouté : convertible en vente, sans impact stock.
- **2026-09-09** — Auth : pas d'inscription publique (l'admin crée les comptes, changement de mot de passe à la 1re connexion) ; session persistante via refresh token long (90 j) révocable ; sync initiale du sous-ensemble du rôle puis delta sync. Voir `docs/spec-fonctionnelle.md` §2bis.

- **2026-09-09** — Socle de sync livré (`POST /api/sync`). Trois décisions prises en l'implémentant :
  1. **Trois issues, deux mémorisées.** `CONFIRMEE` et `REJETEE` sont définitives et mémorisées sur
     `clientMutationId` ; `NON_TRAITEE` ne l'est jamais (panne technique, ou opération dont la feature
     n'est pas encore livrée) et la mutation reste dans la file du client. Raison : mémoriser un rejet
     pour cause de « feature absente » condamnerait définitivement une mutation légitime.
  2. **Colonne `SyncMutation.rejectionCode`** ajoutée (migration additive `20260909065518_sync_rejection_code`).
     Raison : sur un renvoi, le client doit retrouver le **code** métier stable du rejet, pas seulement
     le texte français (CONVENTIONS.md — le front ne se base jamais sur le message).
  3. **Rôle ET permission vérifiés par mutation**, pas seulement la permission. La matrice de
     `docs/permissions.md` combine les deux et un membre peut recevoir une permission « à la carte » ;
     ne contrôler que la permission aurait fait du sync une porte dérobée (un vendeur avec
     `stock.loss` accordé aurait été refusé en ligne mais accepté hors-ligne).
  4. **Une référence introuvable (`NOT_FOUND`) est un rejet DÉFINITIF**, pas un « réessayer plus
     tard ». Raison : la file d'un appareil est ordonnée, l'entité référencée est donc synchronisée
     avant l'opération qui l'utilise ; traiter le cas comme temporaire ferait boucler indéfiniment
     une mutation portant un id erroné. **À rediscuter** si une opération devait un jour référencer
     une entité créée sur un AUTRE appareil.
  5. **Un lot s'arrête à la première panne technique.** Les mutations suivantes repartent `NON_TRAITEE`.
     Raison : les opérations d'un appareil sont ordonnées ; en appliquer une après un trou casserait
     l'ordre (ex. paiement appliqué avant la vente qu'il solde). Un **rejet métier**, lui, n'arrête
     rien : c'est un verdict, pas une panne.

- **2026-09-11** — Correctifs des audits de la feature P0 n°1 (Ratybox, session Claude). Décisions :
  1. **Logout = route PUBLIQUE, le refresh token sert de preuve.** Raison : avec un access token
     expiré, l'intercepteur rafraîchissait d'abord et le logout révoquait l'ANCIEN token, laissant le
     neuf vivant 90 jours. `allDevices` révoque toutes les sessions du titulaire du token.
  2. **Une reconnexion depuis le même `deviceId` remplace la session précédente de cet appareil.**
     Raison : sans cela, chaque réinstallation laissait une session orpheline valable 90 jours.
  3. **`trust proxy` = nombre de sauts (`TRUST_PROXY_HOPS`, 1 en prod derrière Traefik)**, jamais
     `true`. Raison : sinon tout Internet partage le même compteur anti-brute-force et l'audit trace
     l'IP du proxy ; `true` rendrait `X-Forwarded-For` falsifiable.
  4. **Accès relu en base sur les routes sensibles (`FreshAccessGuard`)** plutôt que des access
     tokens plus courts. Raison : garder le JWT sans état partout ailleurs (pas de requête DB par
     appel) tout en fermant la fenêtre de 15 min là où elle permettait une prise de contrôle.
  5. **File de mutations liée à son auteur (Drift v2, `authorUserId`).** Raison : le serveur attribue
     une mutation au porteur du token qui l'envoie ; sur le poste partagé, les opérations d'un compte
     partaient avec la session du suivant (rejets définitifs, ou droits de l'admin prêtés à un
     vendeur). Les mutations d'un autre compte restent en quarantaine sur l'appareil, signalées.
  6. **Configuration refusée au démarrage** si la clé JWT vaut l'exemple ou fait < 32 octets, ou si
     une limite n'est pas un entier. Raison : échouer bruyamment plutôt que tourner sans protection.
  7. **Points de rupture UI 768 / 1180** (AMPÈRE §9), rail d'icônes sur tablette ; **thème persisté
     par utilisateur** (et non par appareil). Raison : conformité au design system validé.

- **2026-09-13** — **Cumul par rôles, plus de permission « à la carte »** (MEDMEDBEN). Un membre qui
  cumule des fonctions reçoit plusieurs rôles. Raison : les guards exigent rôle ET permission, donc une
  permission à la carte n'avait d'effet que sur 2 cas, dont un (VENDEUR + `supplier.read`) contredisait
  la matrice validée. Plus simple, aucune case morte à l'écran. `_UserPermissions` conservée en base
  (plus lue ni écrite) — suppression = migration destructive à confirmer explicitement.

- **2026-09-21** — **Raccordement hors-ligne, tranche A** (MEDMEDBEN, P0 #12). Décisions :
  1. **Le lot déclare son auteur** : `POST /api/sync` exige `authorUserId` (UUID). S'il diffère du
     porteur du token, TOUT le lot revient `NON_TRAITEE` / `SYNC_AUTHOR_MISMATCH`, rien n'est traité ni
     mémorisé. Raison : sur un poste partagé, les mutations d'un compte ne doivent jamais être jugées
     (ni attribuées) sous les droits du compte connecté ; `NON_TRAITEE` et non `REJETEE` car le serveur
     n'a rien jugé — elles repartiront avec la session de leur auteur. Un client antérieur reçoit 400.
  2. **Chemin hybride** : une écriture tente EN LIGNE, et seulement faute de réponse (réseau coupé ou
     délai dépassé) part dans la file sous la MÊME clé que l'intention en ligne. **Précondition pour
     chaque handler de sync** : reconnaître l'entité déjà créée par la route en ligne avec cette clé et
     rendre `CONFIRMEE` sans la réappliquer (l'idempotence du moteur ne lit que `SyncMutation`). Corps
     REST et payload de sync ont la même forme. Une facture ne passe jamais par ce chemin (règle 11).
  3. **Déclenchement** : à la connexion, au retour du réseau, et toutes les 30 s tant qu'une session
     est ouverte (file vide = aucun appel réseau).

<!-- Ajouter ici toute décision importante prise en cours de route, avec la date et la raison. -->
