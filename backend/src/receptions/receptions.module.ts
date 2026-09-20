import { Module } from '@nestjs/common';
import { StockModule } from '../stock/stock.module';
import { ReceptionsController } from './receptions.controller';
import { ReceptionsService } from './receptions.service';

/// Réceptions (P0 n°7) : entrée en stock des quantités réellement reçues,
/// avancement de la commande et dette fournisseur.
@Module({
  imports: [StockModule],
  controllers: [ReceptionsController],
  providers: [ReceptionsService],
})
export class ReceptionsModule {}
