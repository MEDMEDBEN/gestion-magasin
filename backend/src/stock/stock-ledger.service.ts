import { HttpStatus, Injectable } from '@nestjs/common';
import { BusinessException } from '../common/business.exception';
import { ErrorCode } from '../common/error-codes';
import { formatQuantity } from '../common/quantity';
import { Prisma } from '../generated/prisma/client';
import { OperationType, StockMovementType } from '../generated/prisma/enums';

/// Un mouvement à appliquer. `quantity` est un delta SIGNÉ : négatif = sortie.
export interface StockMovementInput {
  /// UUID fourni par le client pour une opération créée hors-ligne (contrat de sync §1).
  movementId?: string;
  productId: string;
  locationId: string;
  quantity: Prisma.Decimal;
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
      select: { id: true, name: true, isActive: true, allowBackorder: true },
    });
    if (!product) {
      throw new BusinessException(
        ErrorCode.NOT_FOUND,
        `Produit introuvable : ${input.productId}`,
        HttpStatus.NOT_FOUND,
      );
    }
    if (!product.isActive) {
      throw new BusinessException(
        ErrorCode.VALIDATION_FAILED,
        `Produit désactivé : « ${product.name} » — aucun mouvement possible`,
        HttpStatus.UNPROCESSABLE_ENTITY,
      );
    }

    const location = await tx.location.findUnique({
      where: { id: input.locationId },
      select: { id: true, name: true, isActive: true },
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
        type: input.type,
        operationType: input.operationType,
        operationId: input.operationId ?? null,
        userId: input.userId ?? null,
        comment: input.comment ?? null,
      },
      select: { id: true },
    });

    return {
      movementId: movement.id,
      quantityAfter: formatQuantity(quantityAfter),
      availableAfter: formatQuantity(availableAfter),
    };
  }
}
