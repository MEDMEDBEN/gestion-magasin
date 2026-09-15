import { Module } from '@nestjs/common';
import { SuppliersController } from '../customers/parties.controller';
import { InventoryController } from '../inventory/inventory.controller';
import {
  AuditController,
  PlanningController,
} from '../planning/planning.controller';
import {
  PurchaseOrdersController,
  ReceptionsController,
} from '../purchases/purchases.controller';
import { SupplierPaymentsController } from '../sales/sales.controller';
import { TransfersController } from '../transfers/transfers.controller';

/// Contrat OpenAPI des endpoints P0 : routes, DTO et guards FIGÉS,
/// implémentations livrées feature par feature (ordre dans docs/plan.md).
/// Chaque route répond 501 + `NOT_IMPLEMENTED` tant que sa feature n'est pas faite.
@Module({
  controllers: [
    SupplierPaymentsController,
    SuppliersController,
    PurchaseOrdersController,
    ReceptionsController,
    TransfersController,
    InventoryController,
    PlanningController,
    AuditController,
  ],
})
export class ApiContractModule {}
