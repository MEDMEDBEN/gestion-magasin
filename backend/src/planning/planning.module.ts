import { Module } from '@nestjs/common';
import { PlanningController } from './planning.controller';
import { PlanningService } from './planning.service';

/// Planning hebdomadaire (P0 n°10) : l'admin planifie, chaque membre exécute
/// ses tâches. Aucun stock, aucun argent.
@Module({
  controllers: [PlanningController],
  providers: [PlanningService],
})
export class PlanningModule {}
