import { Module } from '@nestjs/common';
import { PurchasesModule } from '../purchases/purchases.module';
import { ReplenishmentController } from './replenishment.controller';
import { ReplenishmentService } from './replenishment.service';

/// Réapprovisionnement (P1 n°19) : cet écran propose ce qu'il faut racheter.
/// La préparation des commandes (P2 n°22) crée des BROUILLONS par le chemin de
/// `purchases/` — rien n'est commandé avant la confirmation de l'admin.
///
/// Les alertes STOCK_FAIBLE / RUPTURE qui accompagnent cette feature ne vivent
/// pas ici mais dans `stock/stock-ledger.service.ts` : elles doivent s'écrire
/// dans la transaction du mouvement qui franchit le seuil (règle 3).
@Module({
  imports: [PurchasesModule],
  controllers: [ReplenishmentController],
  providers: [ReplenishmentService],
})
export class ReplenishmentModule {}
