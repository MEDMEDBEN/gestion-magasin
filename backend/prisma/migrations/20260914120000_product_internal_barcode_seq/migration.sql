-- Migration ADDITIVE : séquence des codes-barres internes (CLAUDE.md règle 15).
-- Le code EAN-13 interne = préfixe GS1 « usage interne » 20 + nextval sur 10 chiffres + clé.
-- Une séquence ne revient jamais en arrière : aucun doublon, même après rollback.
CREATE SEQUENCE IF NOT EXISTS "product_internal_barcode_seq" START WITH 1 INCREMENT BY 1 NO CYCLE;
