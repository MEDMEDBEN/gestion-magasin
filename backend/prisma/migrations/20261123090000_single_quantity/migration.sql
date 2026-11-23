-- QUANTITÉ UNIQUE (décision MEDMEDBEN du 2026-11-23) : un produit n'a plus
-- qu'une quantité ; tout le stock vit au MAGASIN.
--
-- Le stock tenu AILLEURS (dépôt, emplacements, transit) est VERSÉ au magasin
-- par des mouvements de transfert, jamais en écrasant une quantité (règle 2) :
-- une sortie là où il était, une entrée au magasin, projections mises à jour
-- dans le même bloc (un seul ordre DO = tout ou rien, règle 3). Rien n'est
-- supprimé : lieux et historique restent (règle 7). Rejouable : une fois versé,
-- il ne reste rien à verser.
DO $$
DECLARE
  store uuid;
BEGIN
  SELECT "id" INTO store
  FROM "Location"
  WHERE "type" = 'MAGASIN' AND "parentId" IS NULL
  ORDER BY "createdAt"
  LIMIT 1;
  -- Base neuve (le magasin est créé après, par le seed) : rien à verser.
  IF store IS NULL THEN
    RETURN;
  END IF;

  CREATE TEMP TABLE "_qty_move" ON COMMIT DROP AS
  SELECT "productId", "locationId" AS "fromId", "quantity"
  FROM "Stock"
  WHERE "locationId" <> store AND "quantity" <> 0;

  INSERT INTO "StockMovement" (
    "id", "productId", "locationId", "quantity", "type",
    "sourceLocationId", "destinationLocationId", "operationType",
    "comment", "createdAt"
  )
  SELECT gen_random_uuid(), "productId", "fromId", -"quantity",
         'TRANSFERT_SORTIE'::"StockMovementType", "fromId", store,
         'TRANSFER'::"OperationType",
         'Quantité unique (2026-11-23) : versé au magasin', now()
  FROM "_qty_move"
  UNION ALL
  SELECT gen_random_uuid(), "productId", store, "quantity",
         'TRANSFERT_ENTREE'::"StockMovementType", "fromId", store,
         'TRANSFER'::"OperationType",
         'Quantité unique (2026-11-23) : versé au magasin', now()
  FROM "_qty_move";

  UPDATE "Stock" s
  SET "quantity" = s."quantity" - m."quantity", "updatedAt" = now()
  FROM "_qty_move" m
  WHERE s."productId" = m."productId" AND s."locationId" = m."fromId";

  INSERT INTO "Stock" ("id", "productId", "locationId", "quantity", "updatedAt")
  SELECT gen_random_uuid(), "productId", store, SUM("quantity"), now()
  FROM "_qty_move"
  GROUP BY "productId"
  ON CONFLICT ("productId", "locationId")
  DO UPDATE SET "quantity" = "Stock"."quantity" + EXCLUDED."quantity",
                "updatedAt" = now();

  -- « À répartir » n'a plus de sens : tout est au même endroit.
  UPDATE "Product" SET "splitPending" = false WHERE "splitPending";

  DROP TABLE "_qty_move";
END $$;
