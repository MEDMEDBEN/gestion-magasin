import { Module } from '@nestjs/common';
import { StockModule } from '../stock/stock.module';
import { InventoryController } from './inventory.controller';
import { InventoryService } from './inventory.service';

/// Inventaire (P0 n°9) : comptage théorique ↔ physique, écarts, et ajustement
/// validé par l'administrateur seul. Le stock passe par `StockLedgerService`.
@Module({
  imports: [StockModule],
  controllers: [InventoryController],
  providers: [InventoryService],
})
export class InventoryModule {}
