import { Module } from '@nestjs/common';
import { StockModule } from '../stock/stock.module';
import { StockLossHandler } from './handlers/stock-loss.handler';
import { SyncController } from './sync.controller';
import { SYNC_MUTATION_HANDLERS, SyncMutationHandler } from './sync-mutation.handler';
import { SyncService } from './sync.service';

/// Socle de synchronisation offline (Phase 0, étape 3).
/// Ajouter une opération synchronisable = écrire un handler et l'inscrire ci-dessous —
/// le moteur (`SyncService`) n'a pas à être modifié.
@Module({
  imports: [StockModule],
  controllers: [SyncController],
  providers: [
    SyncService,
    StockLossHandler,
    {
      provide: SYNC_MUTATION_HANDLERS,
      useFactory: (...handlers: SyncMutationHandler[]) => handlers,
      inject: [StockLossHandler],
    },
  ],
})
export class SyncModule {}
