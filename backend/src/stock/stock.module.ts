import { Module } from '@nestjs/common';
import { StockLedgerService } from './stock-ledger.service';

/// Socle stock partagé. Le `StockController` reste déclaré dans `ApiContractModule`
/// (contrat figé, 501) tant que la feature P0 n°3 « Stock » n'est pas livrée :
/// ce module n'expose donc AUCUNE route, seulement le journal de mouvements.
@Module({
  providers: [StockLedgerService],
  exports: [StockLedgerService],
})
export class StockModule {}
