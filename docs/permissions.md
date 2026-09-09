# Matrice de permissions CRUD — brouillon à VALIDER

> 3 rôles : **Admin**, **Vendeur/Caissier**, **Magasinier**. Un membre peut cumuler des permissions.
> Ceci est une **proposition** — relis et corrige chaque case avant que l'agent code les guards. Une fois validée, elle fait foi ; les guards backend doivent la refléter exactement.
> Légende : ✅ autorisé · ❌ interdit · 👁️ lecture seule · ⚠️ soumis à validation admin.

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
| Gérer fournisseurs | ✅ | ❌ | 👁️ |
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

> Reste éventuellement à préciser plus tard (non bloquant) : plafond de crédit par défaut pour un nouveau client, et si le magasinier peut aussi *confirmer* une commande ou seulement la créer.
