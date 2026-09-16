# Revue générale du projet — 2026-09-16 (commit 4fb965b)

> Demandée par MEDMEDBEN : état complet avant de continuer, sur toutes les couches.
> Aucun code modifié pendant la revue. Méthode : contrôles automatiques relancés + 3 revues
> indépendantes (sécurité globale, backend + base de données, app Flutter), puis les points
> graves **re-vérifiés à la main** dans le code.

## 1. Contrôles automatiques (preuves réelles)

| Contrôle | Résultat |
|---|---|
| `prisma validate` | ✅ schéma valide |
| `prisma migrate status` | ✅ base à jour, 9 migrations toutes additives |
| Schéma ↔ base réelle (`migrate diff`) | ✅ aucun écart |
| Backend `tsc --noEmit` | ✅ 0 erreur |
| Backend `nest build` | ✅ |
| Backend tests unitaires | ✅ 14 suites, **79** tests |
| Backend e2e (`--runInBand`, lancés **seuls**) | ✅ 12 suites, **212** tests |
| App `flutter analyze` | ✅ aucun problème |
| App `flutter test` | ✅ **189** tests (27 ignorés : outil de captures) |
| Backend `eslint` (sans `--fix`) | ❌ ~4 170 erreurs : 36 fichiers en CRLF (prettier) + 17 variables inutilisées dans les stubs 501 |
| `npm audit --omit=dev` | ❌ 8 élevées, 12 modérées, 0 critique (NestJS 10, multer, body-parser, lodash, prisma CLI) |
| Build Windows | ❌ bloqué par un prérequis machine (ATL), déjà connu |
| e2e lancés en parallèle d'autre chose | ⚠️ 28 échecs par timeout (5 s par défaut, base de dev partagée) |

**Conclusion :** le socle est sain — règles non négociables tenues (stock = journal, atomicité,
argent en entiers, décimales, factures sans trou, caisse, permissions serveur). Aucune faille
critique. Mais il reste **3 bloquants** et une série de corrections à faire **avant P0 #7**.

## 2. BLOQUANTS (vérifiés à la main)

| # | Couche | Problème | Où |
|---|---|---|---|
| B1 | Backend / argent | **Annuler une vente peut rendre la caisse négative** : la SORTIE de remboursement n'est pas bornée par le contenu du tiroir (corrigé pour les fournisseurs, pas pour les ventes). | `sales.service.ts` (cancel) |
| B2 | App / argent | **Double paiement possible au réessai manuel** : l'id du règlement client et du paiement fournisseur est recréé à chaque ouverture du dialogue. Après un délai dépassé, recliquer envoie un NOUVEAU paiement. | `sales_screen.dart:878`, `suppliers_screen.dart:185` |
| B3 | App / données | **Le catalogue local ne se met à jour qu'en ouvrant l'écran Catalogue.** Un vendeur sur un poste neuf qui va directement en Vente : « aucun produit », « magasin introuvable » pour ouvrir la caisse, prix périmés. | `catalogSyncProvider` observé seulement par `catalog_screen.dart` |

## 3. IMPORTANTS

### Sécurité
- **S1** `FreshAccessGuard` absent sur `POST /payments/customer`, `POST /cash-sessions`, `POST /cash-sessions/:id/close`, `POST /products` (stock initial), `PATCH /products/:id` (`allowBackorder`), images, catégories, emplacements : un compte désactivé garde ces droits 15 min.
- **S2** Limite de débit **par IP** alors que tout le magasin sort par la même IP : 3 postes qui chargent des photos → 429 pour tout le monde, caisse comprise. Compter par utilisateur sur les routes authentifiées.
- **S3** Pas de limite par compte contre la force brute distribuée (seulement IP + identifiant), échecs de connexion non journalisés.
- **S4** Dépendances vulnérables → passer à NestJS 11 (avant production).
- **S5** Infra : MinIO exposé publiquement par Traefik avec les identifiants **root** partagés avec le backend ; `backend/Dockerfile` et `.dockerignore` **absents** (le compose de prod les référence).
- **S6** Contrat 501 des transferts incohérent avec la matrice (`GET /transfers` refusé au magasinier, annulation vendeur non limitée à « sa demande »).

### Backend / logique
- **L1** Le journal refuse **tout** mouvement sur un produit désactivé → une vente de ce produit ne peut plus être annulée (règle 7). Refuser seulement les sorties.
- **L2** L'unité d'un produit reste modifiable après des mouvements (PIECE → METRE réinterprète tout le journal). Dette notée le 14/09 puis oubliée.
- **L3** `?sort=` accepté puis ignoré sur ventes, clients, fournisseurs, commandes.
- **L4** Listes en N+1 requêtes : clients (2 agrégats par ligne), ventes.
- **L5** Commandes : un PATCH vide écrit un audit et change la version (fait échouer la confirmation) ; deux lignes sur le même produit acceptées (ambigu pour les réceptions partielles de P0 #7).
- **L6** Spec non couverte : échéance/retard client (`Sale.dueDate` jamais rempli), fiche client incomplète, pas d'annulation de règlement/paiement, pas de liste des sessions de caisse pour l'admin (rapport Z introuvable sans id).
- **L7** Tests e2e fragiles : pas de `testTimeout`, base de dev partagée, nettoyage qui casse si `beforeAll` échoue.

### App
- **A1** Pas de saisie de quantité décimale dans le panier (vente au mètre impossible, règle 10).
- **A2** Modifier une commande efface sa note ; méthode de paiement fournisseur forcée à VIREMENT (faux pour « espèces hors tiroir »).
- **A3** Listes chargées en une page (fournisseurs/commandes 200, clients 50) ; sélection produit en liste déroulante de TOUT le catalogue (inutilisable à quelques milliers de produits).
- **A4** Appel caisse lancé même sans le droit caisse (403 inutile) ; contrôleurs non libérés ; décimales non contrôlées dans commandes et pertes.
- **A5** Android release **signée avec la clé de debug**.
- **A6** Pas de localisation française des widgets système.
- **A7** Hors-ligne réel inexistant : app bloquée au démarrage sans réseau, tarifs/clients/stock non mis en cache, file de mutations non branchée, N6b ouvert. (C'est P0 #12, mais à savoir.)

## 4. MINEURS / SUGGESTIONS (résumé)
- DB : `onDelete: Cascade` sur `SaleLine`, `CashMovement`, `PurchaseLine`… → `Restrict` (défense règle 7) ; pas d'index unique « un seul tarif/TVA par défaut » ; le **seed réécrit les défauts à chaque déploiement** ; colonnes jamais écrites (`Customer.code`, `Supplier.code`, `clientMutationId` des ventes…).
- Sécu : `/docs` Swagger ouvert si `NODE_ENV` ≠ `production` ; pas de helmet ; pas d'algorithme JWT imposé ; `page` sans borne haute ; compose de dev qui écoute sur `0.0.0.0` ; table `RefreshToken` jamais purgée ; journal de stock qui montre au vendeur les ids de ventes des collègues.
- Code : `MAX_MONEY`, arrondi monétaire, calcul « contenu du tiroir », verrou client, `_snack` recopiés ; messages d'erreur encore en centimes ; codes d'erreur inutilisés ; à minuit le 31/12 une facture `FA-2026` peut être datée 2027.
- App : paquets inutilisés (`cupertino_icons`, `sqlite3_flutter_libs`), `freezed` en préversion, recherche sans temporisation, logique métier dans les widgets.
- Docs : `docs/tasks.md` contient des sections périmées (phase « P0 #2 en cours », tableau d'avancement faux, dettes soldées).

## 5. Plan de correction proposé (avant de reprendre P0 #7)

1. **Argent et intégrité (bloquants)** : B1, B2, B3 + L1 + S1 (quelques décorateurs).
2. **Stabilité** : S2 (débit par utilisateur), L5 (commandes, prépare P0 #7), L2 (unité figée), L7 (timeout + base e2e dédiée), CRLF → `.gitattributes` + eslint propre, stubs 501 sans lint.
3. **Complétude P0 déjà livrée** : A1 (quantité décimale au panier), A2, L3/L4, L6 (liste des caisses, échéances client, annulation de paiement — décisions métier à prendre).
4. **Avant production** (pas bloquant pour continuer) : S3, S4 (NestJS 11), S5 (Dockerfile, MinIO), A5, A6, mineurs DB (cascades, seed).
5. **Nettoyage de `docs/tasks.md`** (sections périmées).
