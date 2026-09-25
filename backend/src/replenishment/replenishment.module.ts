import { Module } from '@nestjs/common';
import { ReplenishmentController } from './replenishment.controller';
import { ReplenishmentService } from './replenishment.service';

/// Réapprovisionnement (P1 n°19). Lecture seule : cet écran propose ce qu'il
/// faut racheter, il ne commande rien — la commande passe par `purchases/`.
///
/// Les alertes STOCK_FAIBLE / RUPTURE qui accompagnent cette feature ne vivent
/// pas ici mais dans `stock/stock-ledger.service.ts` : elles doivent s'écrire
/// dans la transaction du mouvement qui franchit le seuil (règle 3).
@Module({
  controllers: [ReplenishmentController],
  providers: [ReplenishmentService],
})
export class ReplenishmentModule {}
