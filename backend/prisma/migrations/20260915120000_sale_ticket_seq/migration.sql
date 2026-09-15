-- Migration ADDITIVE : séquence des numéros de ticket (TK-AAAA-NNNNNN).
-- Un ticket n'est pas un document légal : un trou (vente annulée en transaction) est admis.
-- La facture, elle, a son compteur sans trou (InvoiceCounter, en transaction).
CREATE SEQUENCE IF NOT EXISTS "sale_ticket_seq" START WITH 1 INCREMENT BY 1 NO CYCLE;
