# Chèques — suivi des chèques clients et fournisseurs

Retirée du projet le **2026-10-05** (décision MEDMEDBEN : le magasin n'utilise pas les chèques,
ni pour vendre ni pour acheter). État complet d'avant le retrait : tag git `avant-retrait-cheques`.

## Ce que fait la fonctionnalité

- **Règlement client par chèque** : n°, banque, échéance. Le chèque n'entre dans **aucune caisse** ;
  la dette du client baisse dès la remise ; le chèque reste « en portefeuille ».
- **Paiement fournisseur par chèque** : même suivi, jamais sorti du tiroir (`fromCash: false`).
- **Portefeuille** (ADMIN) : liste des chèques (`GET /cheques`), décision par chèque
  (`POST /cheques/{customer|supplier}/:id/status`) : **ENCAISSE**, ou **REJETE** → contre-passation
  (la dette revient) + notification `CHEQUE_REJETE`.
- Garde-fous : chèque fantôme refusé (même clé de mutation, autre chèque), pas d'espèces rendues
  sur un retour contre un chèque pas encore encaissé, chèque encaissé non contre-passable, chèque
  refusé en synchronisation hors ligne (doit être connu de l'admin en ligne).

## Contenu

| Chemin | Rôle |
|---|---|
| `feature-original.patch` | **Le commit d'origine complet** (`9945bd9`), toutes les modifications dans tous les fichiers. C'est la référence pour réintégrer. |
| `backend/src/payments/` | `cheques.controller.ts`, `cheques.service.ts`, `payments.module.ts` (NestJS) |
| `backend/test/cheques.e2e-spec.ts` | Tests d'intégration |
| `backend/prisma/migrations/` | Les 2 migrations (colonnes chèque, statut, notification) |
| `app/lib/features/cheques/` | API, contrôleur Riverpod, écran « Chèques », dialogue de saisie (Flutter) |
| `app/test/cheques_screen_test.dart` | Tests de l'écran |

## Dépendances (à avoir dans le projet cible)

- **Backend** : NestJS + Prisma ; modèles `CustomerPayment` / `SupplierPayment` avec les colonnes
  `chequeNumber`, `chequeBank`, `chequeDueDate`, `chequeStatus` (enum `ChequeStatus` :
  `EN_PORTEFEUILLE`, `ENCAISSE`, `REJETE`) ; enum `NotificationType` avec `CHEQUE_REJETE` ;
  guards `@Roles` / `@RequirePermissions`, `writeAudit`, notifications, `BusinessException`.
- **App** : Flutter, Riverpod, Dio, Freezed (lancer `dart run build_runner build` après copie).

## Points de branchement (ce que le retrait a enlevé ailleurs)

Tous visibles dans `feature-original.patch` :

- `customers.service.ts` : branche `dto.cheque` du règlement client (pas de caisse, méthode
  `CHEQUE`, statut `EN_PORTEFEUILLE`) + reconnaissance de la mutation rejouée.
- `suppliers.service.ts` : idem pour le paiement fournisseur.
- `sale-returns.service.ts` : `cashKept` déduit les chèques non encaissés des espèces rendables.
- `sync/handlers/customer-payment.handler.ts` : refus du chèque hors ligne.
- DTO : `ChequeInputDto` (`common/dto/payment.dto.ts`), champ `cheque` sur les DTO de paiement.
- `app.module.ts` : import de `PaymentsModule`.
- App : bouton « Encaisser un chèque » (vente), « Payer par chèque » (fournisseurs), entrée
  « Chèques » dans `ui/navigation.dart`.
- Tests : `money-routes.ts` (routes argent), `sale-returns.e2e-spec.ts`.

## Réintégrer dans ce projet

```bash
git apply --3way sandbox/cheques/feature-original.patch   # puis résoudre les conflits éventuels
```
Les colonnes et migrations sont **toujours** dans la base de ce projet : aucune migration à refaire.
