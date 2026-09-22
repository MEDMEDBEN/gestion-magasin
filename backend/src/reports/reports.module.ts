import { Module } from '@nestjs/common';
import { DashboardController } from './dashboard.controller';
import { DashboardService } from './dashboard.service';

/// Lectures de synthèse (P1 n°15) : le tableau de bord d'accueil. Aucune
/// écriture, aucun mouvement de stock — que des compteurs recalculés.
@Module({
  controllers: [DashboardController],
  providers: [DashboardService],
})
export class ReportsModule {}
