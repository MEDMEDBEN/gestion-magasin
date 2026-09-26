import { Module } from '@nestjs/common';
import { BusinessReportController } from './business-report.controller';
import { BusinessReportService } from './business-report.service';
import { DashboardController } from './dashboard.controller';
import { DashboardService } from './dashboard.service';
import { ProductReportController } from './product-report.controller';
import { ProductReportService } from './product-report.service';

/// Lectures de synthèse : le tableau de bord d'accueil (P1 n°15), les rapports
/// produits — dormants et demandés (P1 n°20) — et les rapports ventes / stock /
/// achats (P1 n°21). Aucune écriture, aucun mouvement de stock : que des
/// compteurs recalculés à la demande.
///
/// Les deux familles de rapports ne s'ouvrent PAS aux mêmes rôles : les
/// rapports produits rendent des listes et des quantités (trois rôles), les
/// rapports d'activité portent CA, marge et valeur de stock (admin seul).
@Module({
  controllers: [
    DashboardController,
    ProductReportController,
    BusinessReportController,
  ],
  providers: [DashboardService, ProductReportService, BusinessReportService],
})
export class ReportsModule {}
