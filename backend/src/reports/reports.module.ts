import { Module } from '@nestjs/common';
import { DashboardController } from './dashboard.controller';
import { DashboardService } from './dashboard.service';
import { ProductReportController } from './product-report.controller';
import { ProductReportService } from './product-report.service';

/// Lectures de synthèse : le tableau de bord d'accueil (P1 n°15) et les
/// rapports produits — dormants et demandés (P1 n°20). Aucune écriture, aucun
/// mouvement de stock : que des compteurs recalculés à la demande.
@Module({
  controllers: [DashboardController, ProductReportController],
  providers: [DashboardService, ProductReportService],
})
export class ReportsModule {}
