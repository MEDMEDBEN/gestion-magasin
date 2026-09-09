import { Module } from '@nestjs/common';
import {
  CustomersController,
  SuppliersController,
} from '../customers/parties.controller';
import { InventoryController } from '../inventory/inventory.controller';
import { LocationsController } from '../locations/locations.controller';
import {
  AuditController,
  PlanningController,
} from '../planning/planning.controller';
import {
  PurchaseOrdersController,
  ReceptionsController,
} from '../purchases/purchases.controller';
import {
  CashSessionsController,
  PaymentsController,
  SalesController,
} from '../sales/sales.controller';
import { StockController } from '../stock/stock.controller';
import { TransfersController } from '../transfers/transfers.controller';

/// Contrat OpenAPI des endpoints P0 : routes, DTO et guards FIGÉS,
/// implémentations livrées feature par feature (ordre dans docs/plan.md).
/// Chaque route répond 501 + `NOT_IMPLEMENTED` tant que sa feature n'est pas faite.
@Module({
  controllers: [
    LocationsController,
    StockController,
    SalesController,
    CashSessionsController,
    PaymentsController,
    CustomersController,
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
