import { Module } from '@nestjs/common';
import { InventoryController } from '../inventory/inventory.controller';
import {
  AuditController,
  PlanningController,
} from '../planning/planning.controller';

/// Contrat OpenAPI des endpoints P0 : routes, DTO et guards FIGÉS,
/// implémentations livrées feature par feature (ordre dans docs/plan.md).
/// Chaque route répond 501 + `NOT_IMPLEMENTED` tant que sa feature n'est pas faite.
@Module({
  controllers: [InventoryController, PlanningController, AuditController],
})
export class ApiContractModule {}
