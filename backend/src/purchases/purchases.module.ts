import { Module } from '@nestjs/common';
import { PurchaseOrdersController } from './purchase-orders.controller';
import { PurchaseOrdersService } from './purchase-orders.service';

@Module({
  controllers: [PurchaseOrdersController],
  providers: [PurchaseOrdersService],
  // La préparation automatique (P2 n°22) crée ses brouillons par ce chemin.
  exports: [PurchaseOrdersService],
})
export class PurchasesModule {}
