import { Module } from '@nestjs/common';
import { StockLedgerService } from './stock-ledger.service';
import { StockController } from './stock.controller';
import { StockService } from './stock.service';

/// Stock (P0 n°3) : lecture de la projection et du journal, pertes / casse.
/// `StockLedgerService` reste le SEUL point d'écriture du stock, partagé par toutes
/// les opérations (sync, ventes, réceptions, transferts, inventaires).
@Module({
  controllers: [StockController],
  providers: [StockLedgerService, StockService],
  exports: [StockLedgerService, StockService],
})
export class StockModule {}
