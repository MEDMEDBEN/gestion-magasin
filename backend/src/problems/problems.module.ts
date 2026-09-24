import { Module } from '@nestjs/common';
import { StorageModule } from '../storage/storage.module';
import { ProblemsController } from './problems.controller';
import { ProblemsService } from './problems.service';

/// Signalement de problème (P1 n°18, spec §26). Ne touche NI au stock NI à
/// l'argent : il fait savoir, attribue et clôt avec une explication. La
/// correction, elle, passe par les opérations tracées (inventaire, ajustement).
@Module({
  imports: [StorageModule],
  controllers: [ProblemsController],
  providers: [ProblemsService],
})
export class ProblemsModule {}
