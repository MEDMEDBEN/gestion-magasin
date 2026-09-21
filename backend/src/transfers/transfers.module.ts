import { Module } from '@nestjs/common';
import { StockModule } from '../stock/stock.module';
import { TransfersController } from './transfers.controller';
import { TransfersService } from './transfers.service';

/// Transferts dépôt → magasin (P0 n°8) : demande, préparation, expédition,
/// réception. Le stock passe par `StockLedgerService` (règle 2).
@Module({
  imports: [StockModule],
  controllers: [TransfersController],
  providers: [TransfersService],
})
export class TransfersModule {}
