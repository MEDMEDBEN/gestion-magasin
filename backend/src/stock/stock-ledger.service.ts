import { HttpStatus, Injectable } from '@nestjs/common';
import { RoleCode } from '../common/auth.decorators';
import { BusinessException } from '../common/business.exception';
import { ErrorCode } from '../common/error-codes';
import { formatQuantity } from '../common/quantity';
import {
  isLowStock,
  isOutOfStock,
  STOCK_BEARING_LOCATIONS,
} from '../common/replenishment';
import { Prisma } from '../generated/prisma/client';
import { OperationType, StockMovementType } from '../generated/prisma/enums';
import { NotificationsService } from '../notifications/notifications.service';

/// Un mouvement à appliquer. `quantity` est un delta SIGNÉ : négatif = sortie.
export interface StockMovementInput {
  /// UUID fourni par le client pour une opération créée hors-ligne (contrat de sync §1).
  movementId?: string;
  productId: string;
  locationId: string;
  quantity: Prisma.Decimal;
  /// Traçabilité d'un transfert : d'où part la marchandise, où elle va. Purement
  /// informatif (le schéma Phase 0 les prévoit ainsi) — le stock, lui, ne bouge
  /// que par `locationId` et `quantity`.
  sourceLocationId?: string | null;
  destinationLocationId?: string | null;
  type: StockMovementType;
  operationType: OperationType;
  operationId?: string | null;
  userId?: string | null;
  comment?: string | null;
}

export interface AppliedStockMovement {
  movementId: string;
  /// Projection après application, au format de transport (`"77.000"`).
  quantityAfter: string;
  availableAfter: string;
}

/// Noyau du stock — CLAUDE.md règle 2 : `StockMovement` est la SOURCE DE VÉRITÉ
/// (deltas additifs), `Stock.quantity` n'est qu'une projection recalculée dans la
/// MÊME transaction. On n'écrit jamais une quantité absolue.
///
/// Ce service ne porte aucune route : c'est le socle partagé, appelé par le moteur de
/// synchronisation (Phase 0) et, plus tard, par les endpoints en ligne de la feature
/// « Stock » (P0 n°3), des ventes, réceptions, transferts et inventaires.
@Injectable()
export class StockLedgerService {
  /// Applique un mouvement et sa projection, DANS la transaction fournie par l'appelant.
  ///
  /// Anti-stock-négatif (règle 9) : la ligne de projection est verrouillée (`FOR UPDATE`)
  /// avant la vérification, sinon deux ventes concurrentes de la dernière unité
  /// passeraient toutes les deux. Le verrou tient jusqu'au commit de l'appelant.
  async applyMovement(
    tx: Prisma.TransactionClient,
    input: StockMovementInput,
  ): Promise<AppliedStockMovement> {
    if (input.quantity.isZero()) {
      throw new BusinessException(
        ErrorCode.VALIDATION_FAILED,
        'Un mouvement de stock ne peut pas être de quantité nulle',
        HttpStatus.UNPROCESSABLE_ENTITY,
      );
    }

    const product = await tx.product.findUnique({
      where: { id: input.productId },
      select: {
        id: true,
        name: true,
        isActive: true,
        allowBackorder: true,
        // Seuil : sert à l'alerte de fin de méthode, pas à autoriser le
        // mouvement. Lu ici pour ne pas relire le produit une seconde fois.
        // (Pas `safetyStock` : il n'entre que dans la quantité PROPOSÉE, côté
        // liste de réapprovisionnement, jamais dans le déclenchement.)
        minThreshold: true,
      },
    });
    if (!product) {
      throw new BusinessException(
        ErrorCode.NOT_FOUND,
        `Produit introuvable : ${input.productId}`,
        HttpStatus.NOT_FOUND,
      );
    }
    const location = await tx.location.findUnique({
      where: { id: input.locationId },
      select: { id: true, name: true, type: true, isActive: true },
    });
    if (!location) {
      throw new BusinessException(
        ErrorCode.NOT_FOUND,
        `Emplacement introuvable : ${input.locationId}`,
        HttpStatus.NOT_FOUND,
      );
    }
    if (!location.isActive) {
      throw new BusinessException(
        ErrorCode.VALIDATION_FAILED,
        `Emplacement désactivé : « ${location.name} »`,
        HttpStatus.UNPROCESSABLE_ENTITY,
      );
    }

    // Produit désactivé : plus aucune SORTIE (on ne le vend plus). Les ENTRÉES
    // restent possibles — annulation de vente, retour, réception, correction
    // d'inventaire : une opération inverse ne doit jamais être bloquée (règle 7).
    //
    // Exception, MÊME raison, volontairement ÉTROITE : vider le TRANSIT au titre
    // d'un TRANSFERT. Le transit ne porte pas de stock vendable mais de la
    // marchandise déjà partie ; refuser sa sortie la laisserait coincée pour
    // toujours, sans chemin de régularisation (aucune perte ne se déclare en
    // transit). Bornée à `TRANSFER` pour qu'une future opération sur le transit
    // (ajustement d'inventaire…) n'en hérite pas en silence.
    //
    // Et, MÊME raison, les RÉGULARISATIONS : un ajustement d'inventaire ou une
    // perte/casse constatent ce qui n'est plus là. Les refuser sur un produit
    // qu'on vient de désactiver gèlerait son stock résiduel pour toujours — il
    // n'existe aucun autre chemin pour le solder (invariant 4 de CONVENTIONS :
    // une régularisation ne doit jamais être bloquée par une désactivation).
    const regularizing =
      input.operationType === 'INVENTORY' || input.operationType === 'MANUAL';
    const finishingTransfer =
      location.type === 'TRANSIT' && input.operationType === 'TRANSFER';
    if (
      !product.isActive &&
      input.quantity.isNegative() &&
      !regularizing &&
      !finishingTransfer
    ) {
      throw new BusinessException(
        ErrorCode.VALIDATION_FAILED,
        `Produit désactivé : « ${product.name} » — aucune sortie de stock possible`,
        HttpStatus.UNPROCESSABLE_ENTITY,
      );
    }

    // La projection peut ne pas exister encore (premier mouvement de ce produit ici).
    // `ON CONFLICT DO NOTHING` plutôt qu'un upsert Prisma : deux transactions créant la
    // même ligne en même temps ne doivent PAS lever d'erreur d'unicité — en PostgreSQL,
    // une erreur avorte toute la transaction en cours, et le mouvement serait perdu.
    // L'id est un UUID v4 serveur : c'est une ligne de projection, jamais créée par un
    // client, son ordonnancement temporel n'a aucun intérêt.
    await tx.$executeRaw`
      INSERT INTO "Stock" ("id", "productId", "locationId", "updatedAt")
      VALUES (gen_random_uuid(), ${input.productId}::uuid, ${input.locationId}::uuid, now())
      ON CONFLICT ("productId", "locationId") DO NOTHING
    `;

    const [current] = await tx.$queryRaw<
      { quantity: string; reservedQuantity: string }[]
    >`
      SELECT "quantity"::text AS "quantity",
             "reservedQuantity"::text AS "reservedQuantity"
      FROM "Stock"
      WHERE "productId" = ${input.productId}::uuid
        AND "locationId" = ${input.locationId}::uuid
      FOR UPDATE
    `;
    if (!current) {
      throw new BusinessException(
        ErrorCode.CONFLICT,
        'Projection de stock introuvable après création — opération à réessayer',
        HttpStatus.CONFLICT,
      );
    }

    const quantityBefore = new Prisma.Decimal(current.quantity);
    const reserved = new Prisma.Decimal(current.reservedQuantity);
    const quantityAfter = quantityBefore.plus(input.quantity);
    // Le disponible (et non le stock brut) est ce qui autorise une sortie : une quantité
    // déjà réservée n'est plus vendable. Voir `StockDto.availableQuantity`.
    const availableAfter = quantityAfter.minus(reserved);

    // Seule une SORTIE peut être refusée : une entrée ne rend jamais le disponible « plus
    // négatif », et la bloquer empêcherait de régulariser un stock déjà en négatif.
    if (
      input.quantity.isNegative() &&
      availableAfter.isNegative() &&
      !product.allowBackorder
    ) {
      throw new BusinessException(
        ErrorCode.STOCK_NEGATIVE,
        `Stock insuffisant pour « ${product.name} » à « ${location.name} » : ` +
          `disponible ${formatQuantity(quantityBefore.minus(reserved))}, ` +
          `demandé ${formatQuantity(input.quantity.abs())}`,
        HttpStatus.UNPROCESSABLE_ENTITY,
      );
    }

    // Projection additive : jamais d'écriture d'une valeur absolue (règle 2).
    await tx.stock.update({
      where: {
        productId_locationId: {
          productId: input.productId,
          locationId: input.locationId,
        },
      },
      data: { quantity: { increment: input.quantity } },
    });

    const movement = await tx.stockMovement.create({
      data: {
        id: input.movementId,
        productId: input.productId,
        locationId: input.locationId,
        quantity: input.quantity,
        sourceLocationId: input.sourceLocationId ?? null,
        destinationLocationId: input.destinationLocationId ?? null,
        type: input.type,
        operationType: input.operationType,
        operationId: input.operationId ?? null,
        userId: input.userId ?? null,
        comment: input.comment ?? null,
      },
      select: { id: true },
    });

    await this.alertIfThresholdCrossed(tx, input, product, location.type, {
      quantityAfter,
    });

    return {
      movementId: movement.id,
      quantityAfter: formatQuantity(quantityAfter),
      availableAfter: formatQuantity(availableAfter),
    };
  }

  /// Alerte STOCK_FAIBLE / RUPTURE (spec §19), dans la MÊME transaction que le
  /// mouvement : pas de sortie de stock sans son alerte, pas d'alerte pour une
  /// vente qui a échoué (règle 3).
  ///
  /// Elle ne se déclenche qu'au FRANCHISSEMENT, jamais à chaque mouvement :
  /// sans ça, chaque vente d'un produit déjà sous son seuil réécrit la même
  /// alerte et enterre les autres — la leçon des features n°17 et n°18.
  ///
  /// La comparaison porte sur le total du produit en MAGASIN + DÉPÔT, pas sur
  /// l'emplacement touché : on réapprovisionne un PRODUIT chez un fournisseur,
  /// pas une étagère. Un transfert magasin -> dépôt ne doit donc rien déclencher.
  private async alertIfThresholdCrossed(
    tx: Prisma.TransactionClient,
    input: StockMovementInput,
    product: {
      id: string;
      name: string;
      isActive: boolean;
      allowBackorder: boolean;
      minThreshold: Prisma.Decimal;
    },
    locationType: string,
    projection: { quantityAfter: Prisma.Decimal },
  ): Promise<void> {
    // Seule une SORTIE peut faire franchir un seuil vers le bas, et le TRANSIT
    // ne compte pas dans le total : dans les deux cas, rien à calculer.
    if (!input.quantity.isNegative()) return;
    if (locationType === 'TRANSIT') return;

    // Un TRANSFERT ne change pas ce qu'il faut RACHETER : il déplace de la
    // marchandise entre le magasin et le dépôt. Son premier mouvement est
    // pourtant une sortie du dépôt (le transit ne reçoit que le second), donc
    // le total baisse vraiment le temps du trajet et une fausse « RUPTURE
    // URGENTE » partait à chaque expédition qui vidait un produit sous seuil.
    // Trouvé par l'audit sécurité du 2026-09-25 : le commentaire précédent
    // affirmait l'inverse, en s'appuyant sur le filtre TRANSIT ci-dessus qui ne
    // voit que la seconde moitié de l'opération.
    if (input.operationType === 'TRANSFER') return;

    // Produit désactivé : on ne le rachète plus, et la liste de
    // réapprovisionnement l'exclut — alerter renverrait vers un produit
    // introuvable. Les régularisations sur un produit inactif sont permises
    // (voir plus haut), c'est donc un cas réel.
    if (!product.isActive) return;

    // COURT-CIRCUIT, avant toute requête : le total MAGASIN + DÉPÔT est
    // supérieur ou égal au stock de CE seul emplacement dès qu'aucun autre ne
    // peut être négatif — ce que le journal garantit hors « backorder
    // autorisé ». Si cet emplacement reste au-dessus du seuil et de zéro, aucun
    // franchissement n'est possible : rien à agréger.
    //
    // Ce n'est pas une micro-optimisation : sans lui, une validation
    // d'inventaire de 1000 lignes ajoutait 1000 agrégats à UNE transaction
    // (audit sécurité — risque de dépasser le délai et de tout annuler). Avec
    // lui, le catalogue par défaut (seuil à 0) ne paie plus rien tant que le
    // stock reste positif.
    //
    // Effet de bord accepté : si le drapeau « backorder » a été retiré APRÈS
    // qu'un emplacement est passé en négatif, une alerte peut être manquée sur
    // ce mouvement-là. Le suivant la rattrape, et la liste dit toujours vrai.
    if (
      !product.allowBackorder &&
      projection.quantityAfter.greaterThan(product.minThreshold) &&
      projection.quantityAfter.greaterThan(0)
    ) {
      return;
    }

    const [row] = await tx.$queryRaw<{ total: string }[]>`
      SELECT COALESCE(SUM(s."quantity"), 0)::text AS "total"
      FROM "Stock" s
      JOIN "Location" l ON l."id" = s."locationId"
      WHERE s."productId" = ${product.id}::uuid
        AND l."type"::text IN (${Prisma.join([...STOCK_BEARING_LOCATIONS])})
    `;
    const totalAfter = new Prisma.Decimal(row?.total ?? 0);
    // La projection est déjà à jour : l'état d'avant se retrouve en retirant le
    // delta, sans seconde lecture ni état gardé quelque part.
    const totalBefore = totalAfter.minus(input.quantity);

    const rupture = isOutOfStock(totalAfter) && !isOutOfStock(totalBefore);
    const faible =
      !rupture &&
      isLowStock(totalAfter, product.minThreshold) &&
      !isLowStock(totalBefore, product.minThreshold);
    if (!rupture && !faible) return;

    // Une alerte NON LUE du MÊME type sur ce produit suffit : ne pas la
    // réécrire. Le type compte : une RUPTURE doit passer même quand un
    // STOCK_FAIBLE non lu traîne — c'est une AGGRAVATION, pas une répétition
    // (mon propre test l'a rattrapé : la rupture était étouffée).
    //
    // Le franchissement se réarme dès que le stock repasse au-dessus du seuil ;
    // une boucle vente -> annulation produisait donc une alerte par cycle et
    // enterrait les autres — le risque que la garde de franchissement visait
    // (audit sécurité du 2026-09-25). Tant que personne n'a lu la précédente,
    // elle dit déjà la même chose.
    //
    // La déduplication est GLOBALE et non par destinataire, volontairement : un
    // membre arrivé entre-temps ne recevra pas cette alerte-là, mais l'écran
    // Réappro dit toujours l'état réel — une alerte n'est qu'un rappel.
    const dejaSignale = await tx.notification.findFirst({
      where: {
        operationType: 'PRODUCT',
        operationId: product.id,
        type: rupture ? 'RUPTURE' : 'STOCK_FAIBLE',
        isRead: false,
      },
      select: { id: true },
    });
    if (dejaSignale) return;

    await NotificationsService.notifyRoles(
      tx,
      // Ceux qui peuvent AGIR : l'admin achète, le magasinier tient le stock.
      // Le vendeur n'a ni `purchase.create` ni l'accès fournisseurs.
      [RoleCode.ADMIN, RoleCode.MAGASINIER],
      {
        type: rupture ? 'RUPTURE' : 'STOCK_FAIBLE',
        title: rupture
          ? `Rupture : « ${product.name} »`
          : `Stock faible : « ${product.name} »`,
        body: rupture
          ? 'Plus rien en magasin ni au dépôt.'
          : `Il reste ${formatQuantity(totalAfter)} pour un seuil de ` +
            `${formatQuantity(product.minThreshold)}.`,
        operationType: 'PRODUCT',
        operationId: product.id,
        priority: rupture ? 'URGENTE' : 'HAUTE',
      },
      // Celui qui vient de faire le mouvement le sait déjà.
      input.userId ?? undefined,
    );
  }
}
