# Matrice de permissions CRUD — **VALIDÉE le 2026-09-09**

> 3 rôles : **Admin**, **Vendeur/Caissier**, **Magasinier**. Un membre peut cumuler des permissions.
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

Le plafond `Customer.creditLimit` est un **entier en centimes**, `@default(0)` dans le schéma Prisma :
un client neuf ne peut donc pas acheter à crédit tant que l'admin n'a rien fixé.

## Produits / Catégories / Emplacements
| Action | Admin | Vendeur/Caissier | Magasinier |
|---|---|---|---|
| Consulter | ✅ | ✅ | ✅ |
| Créer / modifier produit | ✅ | ❌ | ❌ |
| Désactiver produit | ✅ | ❌ | ❌ |
| Modifier prix / tarifs | ✅ | ❌ | ❌ |
| Voir les prix / tarifs | ✅ | ✅ (lecture directe) | 👁️ |
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
| Émettre une facture (n° légal) | ✅ | ✅ | ❌ |
| Annuler une vente validée | ✅ | ❌ | ❌ |
| Ouvrir / clôturer une caisse | ✅ | ✅ (sa caisse) | ❌ |
| Voir le rapport Z | ✅ | 👁️ (sa session) | ❌ |

## Clients / Fournisseurs / Dettes
| Action | Admin | Vendeur/Caissier | Magasinier |
|---|---|---|---|
| Consulter clients | ✅ | ✅ | 👁️ |
| Créer / modifier client | ✅ | ✅ | ❌ |
| Enregistrer paiement client | ✅ | ✅ | ❌ |
| Consulter fournisseurs | ✅ | ❌ | 👁️ (`supplier.read`) |
| Gérer fournisseurs | ✅ | ❌ | ❌ |
| Enregistrer paiement fournisseur | ✅ | ❌ | ❌ |

## Achats / Réceptions
| Action | Admin | Vendeur/Caissier | Magasinier |
|---|---|---|---|
| Créer / modifier commande fournisseur | ✅ | ❌ | ✅ |
| Confirmer / annuler commande | ✅ | ❌ | ❌ |
| Réceptionner (partielle incluse) | ✅ | ❌ | ✅ |

## Transferts magasin ↔ dépôt
| Action | Admin | Vendeur/Caissier | Magasinier |
|---|---|---|---|
| Créer une demande (magasin) | ✅ | ✅ | ❌ |
| Accepter / préparer / expédier | ✅ | ❌ | ✅ |
| Réceptionner au magasin | ✅ | ✅ | ❌ |
| Refuser / annuler | ✅ | ⚠️ (sa demande) | ✅ (préparation) |

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
