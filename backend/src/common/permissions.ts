import { RoleCode } from './auth.decorators';

/// Catalogue des permissions atomiques — transcription EXACTE de `docs/permissions.md`
/// (matrice validée le 2026-09-09). Source unique : le seed et les guards lisent ceci.
/// Toute évolution passe d'abord par une mise à jour de `docs/permissions.md`.
export const PERMISSIONS = {
  // Produits / catégories / emplacements
  PRODUCT_READ: 'product.read',
  PRODUCT_WRITE: 'product.write',
  PRODUCT_DISABLE: 'product.disable',
  /// Prix & tarifs : ADMIN uniquement (décision figée).
  PRICE_MANAGE: 'price.manage',
  PRICE_READ: 'price.read',
  /// Coût d'achat (dernier prix réceptionné, base de la marge) : ADMIN et
  /// MAGASINIER — jamais le vendeur (décision MEDMEDBEN 2026-09-14).
  COST_READ: 'cost.read',
  LOCATION_MANAGE: 'location.manage',

  // Stock
  STOCK_READ_STORE: 'stock.read.store',
  STOCK_READ_WAREHOUSE: 'stock.read.warehouse',
  STOCK_ADJUST: 'stock.adjust',
  STOCK_ADJUST_VALIDATE: 'stock.adjust.validate',
  STOCK_LOSS: 'stock.loss',

  // Ventes / caisse
  SALE_CREATE: 'sale.create',
  /// Remise sur ligne : ADMIN uniquement — pas de remise libre du vendeur.
  SALE_DISCOUNT: 'sale.discount',
  /// Vente à crédit, plafonnée par `Customer.creditLimit` (0 = pas de crédit).
  SALE_CREDIT: 'sale.credit',
  INVOICE_ISSUE: 'invoice.issue',
  SALE_CANCEL: 'sale.cancel',
  CASH_SESSION_MANAGE: 'cash.session.manage',
  CASH_REPORT_READ: 'cash.report.read',

  // Clients / fournisseurs / dettes
  CUSTOMER_READ: 'customer.read',
  CUSTOMER_WRITE: 'customer.write',
  CUSTOMER_PAYMENT_CREATE: 'customer.payment.create',
  SUPPLIER_READ: 'supplier.read',
  SUPPLIER_WRITE: 'supplier.write',
  SUPPLIER_PAYMENT_CREATE: 'supplier.payment.create',

  // Achats / réceptions
  PURCHASE_CREATE: 'purchase.create',
  /// Confirmation / annulation d'une commande : ADMIN seul.
  PURCHASE_CONFIRM: 'purchase.confirm',
  RECEPTION_CREATE: 'reception.create',

  // Transferts
  TRANSFER_REQUEST: 'transfer.request',
  TRANSFER_PREPARE: 'transfer.prepare',
  TRANSFER_RECEIVE: 'transfer.receive',
  TRANSFER_CANCEL: 'transfer.cancel',

  // Inventaire / planning
  INVENTORY_CREATE: 'inventory.create',
  INVENTORY_VALIDATE: 'inventory.validate',
  PLANNING_MANAGE: 'planning.manage',
  PLANNING_TASK_READ: 'planning.task.read',

  // Administration
  USER_MANAGE: 'user.manage',
  SETTINGS_MANAGE: 'settings.manage',
  AUDIT_READ: 'audit.read',
} as const;

export type PermissionCode = (typeof PERMISSIONS)[keyof typeof PERMISSIONS];

const P = PERMISSIONS;

/// Permissions accordées par défaut à chaque rôle.
/// L'admin peut en accorder d'autres à un membre au cas par cas (cumul).
export const ROLE_PERMISSIONS: Record<RoleCode, PermissionCode[]> = {
  // Accès complet.
  [RoleCode.ADMIN]: Object.values(P),

  [RoleCode.VENDEUR]: [
    P.PRODUCT_READ,
    P.PRICE_READ,
    // Décision MEDMEDBEN 2026-09-22 : le vendeur voit le coût d'achat, plancher
    // du prix qu'il peut modifier en vente (avant : secret, décision 2026-09-14).
    P.COST_READ,
    P.STOCK_READ_STORE,
    P.STOCK_READ_WAREHOUSE,
    P.SALE_CREATE,
    P.SALE_CREDIT,
    P.INVOICE_ISSUE,
    P.CASH_SESSION_MANAGE,
    P.CASH_REPORT_READ,
    P.CUSTOMER_READ,
    P.CUSTOMER_WRITE,
    P.CUSTOMER_PAYMENT_CREATE,
    // Pas de `SUPPLIER_READ` : la matrice ferme les fournisseurs au vendeur.
    P.TRANSFER_REQUEST,
    P.TRANSFER_RECEIVE,
    P.TRANSFER_CANCEL,
    P.PLANNING_TASK_READ,
  ],

  [RoleCode.MAGASINIER]: [
    P.PRODUCT_READ,
    P.PRICE_READ,
    P.COST_READ,
    P.LOCATION_MANAGE,
    P.STOCK_READ_STORE,
    P.STOCK_READ_WAREHOUSE,
    P.STOCK_ADJUST,
    P.STOCK_LOSS,
    P.CUSTOMER_READ,
    P.SUPPLIER_READ,
    P.PURCHASE_CREATE,
    P.RECEPTION_CREATE,
    P.TRANSFER_PREPARE,
    P.TRANSFER_CANCEL,
    P.INVENTORY_CREATE,
    P.PLANNING_TASK_READ,
  ],
};

export const ROLE_LABELS: Record<RoleCode, string> = {
  [RoleCode.ADMIN]: 'Administrateur',
  [RoleCode.VENDEUR]: 'Vendeur / Caissier',
  [RoleCode.MAGASINIER]: 'Magasinier',
};

export const PERMISSION_DESCRIPTIONS: Record<string, string> = {
  [P.PRODUCT_READ]: 'Consulter les produits, catégories et emplacements',
  [P.PRODUCT_WRITE]: 'Créer et modifier un produit',
  [P.PRODUCT_DISABLE]: 'Désactiver un produit',
  [P.PRICE_MANAGE]: 'Modifier les prix et les tarifs (admin uniquement)',
  [P.PRICE_READ]: 'Voir les prix et les tarifs',
  [P.COST_READ]: 'Voir le coût d’achat et la marge',
  [P.LOCATION_MANAGE]: 'Gérer les emplacements du dépôt',
  [P.STOCK_READ_STORE]: 'Consulter le stock magasin',
  [P.STOCK_READ_WAREHOUSE]: 'Consulter le stock dépôt',
  [P.STOCK_ADJUST]:
    "Créer un ajustement d'inventaire (soumis à validation admin)",
  [P.STOCK_ADJUST_VALIDATE]: "Valider un ajustement d'inventaire",
  [P.STOCK_LOSS]: 'Déclarer une perte ou une casse',
  [P.SALE_CREATE]: 'Créer une vente',
  [P.SALE_DISCOUNT]: 'Appliquer une remise sur une ligne (admin uniquement)',
  [P.SALE_CREDIT]: 'Vendre à crédit dans la limite du client',
  [P.INVOICE_ISSUE]: 'Émettre une facture avec numéro légal',
  [P.SALE_CANCEL]: 'Annuler une vente validée',
  [P.CASH_SESSION_MANAGE]: 'Ouvrir et clôturer une session de caisse',
  [P.CASH_REPORT_READ]: 'Consulter le rapport Z',
  [P.CUSTOMER_READ]: 'Consulter les clients',
  [P.CUSTOMER_WRITE]: 'Créer et modifier un client',
  [P.CUSTOMER_PAYMENT_CREATE]: 'Enregistrer un paiement client',
  [P.SUPPLIER_READ]: 'Consulter les fournisseurs',
  [P.SUPPLIER_WRITE]: 'Créer et modifier un fournisseur',
  [P.SUPPLIER_PAYMENT_CREATE]: 'Enregistrer un paiement fournisseur',
  [P.PURCHASE_CREATE]: 'Créer et modifier une commande fournisseur',
  [P.PURCHASE_CONFIRM]:
    'Confirmer ou annuler une commande fournisseur (admin seul)',
  [P.RECEPTION_CREATE]: 'Réceptionner une commande, y compris partiellement',
  [P.TRANSFER_REQUEST]: 'Créer une demande de transfert vers le magasin',
  [P.TRANSFER_PREPARE]: 'Accepter, préparer et expédier un transfert',
  [P.TRANSFER_RECEIVE]: 'Réceptionner un transfert au magasin',
  [P.TRANSFER_CANCEL]: 'Refuser ou annuler un transfert',
  [P.INVENTORY_CREATE]: 'Lancer un inventaire ou un comptage',
  [P.INVENTORY_VALIDATE]: "Valider un ajustement d'inventaire",
  [P.PLANNING_MANAGE]: 'Créer et gérer le planning hebdomadaire',
  [P.PLANNING_TASK_READ]: 'Voir et exécuter ses tâches planifiées',
  [P.USER_MANAGE]: 'Gérer les utilisateurs, rôles et permissions',
  [P.SETTINGS_MANAGE]: 'Modifier les paramètres système',
  [P.AUDIT_READ]: "Consulter le journal d'audit",
};
