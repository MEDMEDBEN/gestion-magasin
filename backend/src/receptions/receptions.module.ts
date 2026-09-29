import { Module } from '@nestjs/common';
import { StockModule } from '../stock/stock.module';
import { ReceptionsController } from './receptions.controller';
import { InvoiceScanService } from './invoice-scan';
import { ReceptionsService } from './receptions.service';

/// Réceptions (P0 n°7) : entrée en stock des quantités réellement reçues,
/// avancement de la commande et dette fournisseur.
@Module({
  imports: [StockModule],
  controllers: [ReceptionsController],
  providers: [ReceptionsService, InvoiceScanService],
  exports: [ReceptionsService],
})
export class ReceptionsModule {}
