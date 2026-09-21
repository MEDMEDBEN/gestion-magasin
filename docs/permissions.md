# Matrice de permissions CRUD — **VALIDÉE le 2026-09-09**

> 3 rôles : **Admin**, **Vendeur/Caissier**, **Magasinier**. Un membre peut cumuler des fonctions **en recevant plusieurs rôles**.
> Cette matrice est **validée et fait foi**. Les guards backend la reflètent exactement — toute
> évolution passe d'abord par ce fichier, puis par `backend/src/common/permissions.ts`.
> Légende : ✅ autorisé · ❌ interdit · 👁️ lecture seule · ⚠️ soumis à validation admin.

## Règles fermes (validées — non négociables)

1. **Prix & tarifs : ADMIN uniquement.** Le vendeur voit et applique les tarifs, il n'en fixe aucun.
2. **Aucune remise libre du vendeur.** La remise sur ligne (`sale.discount`) est réservée à l'ADMIN.
3. **Vente à crédit** : autorisée au vendeur, strictement **dans la limite de `Customer.creditLimit`**
   fixée par l'admin. **Défaut = 0, donc pas de crédit** tant que l'admin n'a pas relevé le plafond.
4. **Commandes fournisseurs** : créées et modifiées par l'**ADMIN et le MAGASINIER**.
5. **Confirmation / annulation d'une commande : ADMIN seul.**

### Traduction technique (source unique : `backend/src/common/permissions.ts`)

| Règle | Permission | Rôles porteurs |
|---|---|---|
| Prix & tarifs admin only | `price.manage` | ADMIN |
| Pas de remise libre | `sale.discount` | ADMIN |
| Vente à crédit plafonnée | `sale.credit` | ADMIN, VENDEUR |
| Commande fournisseur | `purchase.create` | ADMIN, MAGASINIER |
| Confirmation commande | `purchase.confirm` | ADMIN |
| Clôture du reliquat d'une commande partiellement reçue | `purchase.confirm` | ADMIN |

Le plafond `Customer.creditLimit` est un **entier en centimes**, `@default(0)` dans le schéma Prisma :
un client neuf ne peut donc pas acheter à crédit tant que l'admin n'a rien fixé.

**Cumul = par RÔLES, jamais par permission « à la carte »** (décision de MEDMEDBEN, 2026-09-13).
Un membre qui cumule des fonctions reçoit **plusieurs rôles** ; ses permissions effectives sont
l'union de celles de ses rôles. Il n'existe plus de permission accordée individuellement.
Raison : les guards exigent RÔLE **et** permission, donc une permission à la carte n'avait d'effet
que sur 2 cas — dont VENDEUR + `supplier.read`, qui contredisait la présente matrice (« vendeur :
aucun accès fournisseurs »). Conséquence technique : le champ `extraPermissions` n'existe plus
(refusé en 400) et la table `_UserPermissions` n'est plus ni lue ni écrite (conservée en base,
aucune migration destructive sans confirmation).

## Produits / Catégories / Emplacements
| Action | Admin | Vendeur/Caissier | Magasinier |
|---|---|---|---|
| Consulter | ✅ | ✅ | ✅ |
| Créer / modifier produit | ✅ | ❌ | ❌ |
| Désactiver produit | ✅ | ❌ | ❌ |
| Modifier prix / tarifs | ✅ | ❌ | ❌ |
| Voir les prix / tarifs | ✅ | ✅ (lecture directe) | 👁️ |
| Voir le coût d'achat (marge) | ✅ | ❌ | 👁️ (`cost.read`) |
| Gérer emplacements dépôt | ✅ | ❌ | ✅ |

## Stock / Mouvements
| Action | Admin | Vendeur/Caissier | Magasinier |
|---|---|---|---|
| Consulter stock magasin | ✅ | ✅ | ✅ |
| Consulter stock dépôt | ✅ | 👁️ | ✅ |
| Ajustement d'inventaire | ✅ | ❌ | ⚠️ (crée, validé par admin) |
| Perte / casse | ✅ | ❌ | ⚠️ |

## Ventes / Caisse
| Action | Admin | Vendeur/Caissier | Magasinier |
|---|---|---|---|
| Créer une vente | ✅ | ✅ | ❌ |
| Appliquer une remise sur ligne | ✅ | ❌ | ❌ |
| Vendre à crédit | ✅ | ✅ (dans la limite du client fixée par l'admin) | ❌ |
| Fixer l'échéance d'une vente à crédit | ✅ | ✅ (obligatoire, aujourd'hui ou plus tard) | ❌ |
| Émettre une facture (n° légal) | ✅ | ✅ | ❌ |
| Annuler une vente validée | ✅ | ❌ | ❌ |
| Ouvrir / clôturer une caisse | ✅ | ✅ (sa caisse) | ❌ |
| Voir le rapport Z | ✅ | 👁️ (sa session) | ❌ |
| Lister TOUTES les caisses (`GET /cash-sessions`) | ✅ (`cash.report.read`) | ❌ | ❌ |

> **Décisions MEDMEDBEN du 2026-09-16 (appliquées le 2026-09-17)**
> - **Annulation d'un paiement = CONTRE-PASSATION, jamais suppression** (règle 7) : ADMIN seul, motif obligatoire,
>   une seule fois par paiement, et une contre-passation ne se contre-passe pas. Les espèces repassent par la caisse
>   OUVERTE de l'admin (sortie pour un règlement client rendu, entrée pour un paiement fournisseur récupéré) ; un
>   paiement fournisseur fait hors caisse ne touche pas la caisse. Aucune permission nouvelle : `customer.payment.create`
>   / `supplier.payment.create` + rôle ADMIN.
> - **Liste des caisses** : réservée à l'ADMIN (`cash.report.read`). Le vendeur ne voit toujours que SA session.
> - **Échéance** : obligatoire dès qu'une vente laisse du crédit ; la fiche client expose le montant EN RETARD.
> - **Toute écriture** (argent, stock, catalogue, comptes) relit les droits EN BASE via le guard global
>   `FreshAccessGuard` — un compte désactivé ou rétrogradé perd l'accès immédiatement, sans attendre l'expiration du token.

## Clients / Fournisseurs / Dettes
| Action | Admin | Vendeur/Caissier | Magasinier |
|---|---|---|---|
| Consulter clients | ✅ | ✅ | 👁️ |
| Créer / modifier client | ✅ | ✅ | ❌ |
| Enregistrer paiement client | ✅ | ✅ | ❌ |
| Consulter l'historique des règlements d'un client | ✅ | ✅ | 👁️ |
| Contre-passer un règlement client | ✅ | ❌ | ❌ |
| Consulter fournisseurs | ✅ | ❌ | 👁️ (`supplier.read`) |
| Gérer fournisseurs | ✅ | ❌ | ❌ |
| Enregistrer paiement fournisseur | ✅ | ❌ | ❌ |
| Consulter l'historique des paiements fournisseur | ✅ | ❌ | 👁️ (`supplier.read`) |
| Contre-passer un paiement fournisseur | ✅ | ❌ | ❌ |

## Achats / Réceptions
| Action | Admin | Vendeur/Caissier | Magasinier |
|---|---|---|---|
| Créer / modifier commande fournisseur | ✅ | ❌ | ✅ |
| Confirmer / annuler commande | ✅ | ❌ | ❌ |
| Réceptionner (partielle incluse) sur une commande confirmée | ✅ | ❌ | ✅ |
| Réceptionner **hors commande** | ✅ | ❌ | ❌ |

**Décisions du 2026-09-20 (audit sécurité de P0 #7)**
- **Le prix d'achat vient de la commande confirmée**, jamais du bon de réception : l'admin engage le prix en
  confirmant, le magasinier constate les quantités. Le prix envoyé sur une ligne rattachée à une commande est
  ignoré. Il ne sert que sur une réception hors commande.
- **La réception hors commande est réservée à l'ADMIN** : sans commande, elle crée du stock, de la dette
  fournisseur et un coût d'achat sans qu'aucun administrateur n'ait rien engagé — c'est un achat complet.
  Le magasinier crée d'abord la commande, l'admin la confirme, puis la réception suit le chemin normal.
- Les lectures de réceptions (`GET /receptions`) portent la permission `reception.create` : la matrice
  n'accorde « Réceptionner » qu'à l'admin et au magasinier et ne prévoit pas de droit de lecture distinct.

## Transferts magasin ↔ dépôt
| Action | Admin | Vendeur/Caissier | Magasinier |
|---|---|---|---|
| Créer une demande (magasin) | ✅ | ✅ | ❌ |
| Accepter / préparer / expédier | ✅ | ❌ | ✅ |
| Réceptionner au magasin | ✅ | ✅ | ❌ |
| Refuser / annuler | ✅ | ⚠️ (sa demande) | ✅ (préparation) |

**Décisions du 2026-09-21 (implémentation de P0 #8)** — le « ⚠️ » est appliqué à la lettre :
- **REFUSER** (`REFUSEE`) est un geste du DÉPÔT : réservé à l'ADMIN et au MAGASINIER.
- **ANNULER** (`ANNULEE`) est un geste du DEMANDEUR : ADMIN, ou le vendeur **auteur** de la demande.
  Un autre vendeur reçoit 403 ; le magasinier n'annule pas, il refuse.
- Les deux ne sont possibles **que tant que rien n'est expédié**. Après l'expédition, la marchandise
  est en transit : le transfert doit être réceptionné (règle 7), l'écart éventuel retourne au dépôt.
- **Lecture** (`GET /transfers`, `GET /transfers/:id`) : ouverte aux TROIS rôles par un guard de
  RÔLE seul, sans permission supplémentaire. Chacun tient un bout du flux et doit voir le même
  tableau ; aucune permission existante n'est commune aux trois, et en inventer une dépasserait
  cette matrice.

## Inventaire / Planning
| Action | Admin | Vendeur/Caissier | Magasinier |
|---|---|---|---|
| Lancer un inventaire / comptage | ✅ | ❌ | ✅ |
| Valider un ajustement d'inventaire | ✅ | ❌ | ❌ |
| Créer un planning hebdomadaire | ✅ | ❌ | ❌ |
| Voir / exécuter ses tâches planifiées | ✅ | ✅ | ✅ |

## Administration
| Action | Admin | Vendeur/Caissier | Magasinier |
|---|---|---|---|
| Gérer utilisateurs / rôles / permissions | ✅ | ❌ | ❌ |
| Modifier les paramètres système | ✅ | ❌ | ❌ |
| Consulter l'audit / traçabilité | ✅ | ❌ | ❌ |

## Décision du 2026-09-14 (MEDMEDBEN) — perte / casse du magasinier
- Le « ⚠️ » de la matrice est appliqué à la lettre : une perte déclarée par le **MAGASINIER** crée une
  `StockLossDeclaration` **EN_ATTENTE** ; le stock ne bouge qu'à la **validation de l'ADMIN**
  (`stock.adjust.validate`). Refusée : aucun mouvement, la déclaration reste en historique.
- L'ADMIN qui déclare applique directement. Même règle hors-ligne (handler de sync `MANUAL`).
- Les droits qui décident « appliquer / valider » sont relus EN BASE (`FreshAccessGuard` sur les routes de
  pertes ET sur `POST /sync`) : un admin rétrogradé perd la main tout de suite.
- Le VENDEUR voit dans le journal les mouvements `PERTE_CASSE` (le stock doit rester explicable), mais
  **ni le constat, ni le déclarant** (`comment`, `userId`, `operationId` masqués sans `stock.loss`).

## Décision du 2026-09-14 (MEDMEDBEN) — coût d'achat
- Le **coût d'achat** (`Product.lastPurchasePriceHt`, dernier prix réceptionné = base de la marge) est
  visible par l'**ADMIN et le MAGASINIER** (permission `cost.read`), **jamais par le vendeur**. Le serveur
  renvoie `null` à qui n'a pas `cost.read`, sur toute réponse produit (liste, fiche, code-barres, delta).
- Même traitement pour `mainSupplierId` sans `supplier.read` (le vendeur n'a aucun accès fournisseurs).
- L'app n'enregistre **jamais** ces deux champs dans sa base locale (partagée par les comptes d'un poste).

## Décisions figées (2026-09-09)
- **Prix & tarifs : gérés par l'admin uniquement.** Le vendeur ne fixe aucun prix et n'applique **aucune remise libre** — il voit et applique les tarifs définis par l'admin.
- **Vente à crédit** : autorisée au vendeur, dans la **limite de crédit du client** définie par l'admin.
- **Commandes fournisseurs** : créées/modifiées par l'**admin ET le magasinier**. Confirmation/annulation = admin.
- **Plafond de crédit par défaut = 0** pour tout nouveau client (aucun crédit sans décision explicite de l'admin).
- **Le magasinier ne peut PAS confirmer une commande** — il la crée et la modifie, la confirmation reste à l'admin.
- **Le vendeur n'a AUCUN accès aux fournisseurs** (ni lecture ni écriture). La ligne « Gérer fournisseurs »
  était ambiguë entre lecture et gestion : elle est scindée ci-dessus. `supplier.read` est accordé à
  l'admin et au magasinier uniquement.

## Implémentation (2026-09-09)

Cette matrice est appliquée par deux guards globaux, dans cet ordre :
`JwtAccessGuard` (authentifie, pose `req.user`) puis `RolesGuard` (autorise).

**Garde-fou** : une route authentifiée **sans `@Roles(...)` explicite est refusée** (`FORBIDDEN_ROLE`).
Oublier le décorateur ferme la route au lieu de l'ouvrir — conformément à la règle 1 de `CLAUDE.md`.
Les permissions atomiques (`@RequirePermissions(...)`) sont exigées **en plus** du rôle, toutes.

**Gestion des comptes — garde-fous (2026-09-11, suite aux audits de la feature P0 #1)** :
- `FreshAccessGuard` sur `/users` : l'accès (actif + rôles) est relu **en base** à
  chaque appel ; un admin désactivé ou rétrogradé perd la main tout de suite, sans attendre
  l'expiration de son access token (15 min).
- Un admin ne modifie **ni ses propres rôles, ni sa propre activation**
  (`SELF_MODIFICATION_FORBIDDEN`) : ces changements passent par un autre administrateur.
- Le système garde toujours **au moins un admin actif** (`LAST_ACTIVE_ADMIN`), contrôle fait sous
  verrou dans la transaction (deux admins qui se retirent mutuellement : il en reste un).
- L'UI dérive ses menus des mêmes règles (`app/lib/ui/navigation.dart`), sans jamais s'y substituer.
