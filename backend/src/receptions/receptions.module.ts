import { Module } from '@nestjs/common';
import { StockModule } from '../stock/stock.module';
import { DirectPurchaseController } from './direct-purchase.controller';
import { DirectPurchaseService } from './direct-purchase';
import { ReceptionsController } from './receptions.controller';
import { InvoiceScanService } from './invoice-scan';
import { ReceptionsService } from './receptions.service';

/// Réceptions (P0 n°7) : entrée en stock des quantités réellement reçues,
/// avancement de la commande et dette fournisseur.
@Module({
  imports: [StockModule],
  controllers: [ReceptionsController, DirectPurchaseController],
  providers: [ReceptionsService, InvoiceScanService, DirectPurchaseService],
  exports: [ReceptionsService, DirectPurchaseService],
})
export class ReceptionsModule {}
