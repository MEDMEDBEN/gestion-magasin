import { Module } from '@nestjs/common';
import { StockModule } from '../stock/stock.module';
import { CashSessionsController } from './cash-sessions.controller';
import { CashSessionsService } from './cash-sessions.service';
import { SalesController } from './sales.controller';
import { SalesService } from './sales.service';

@Module({
  imports: [StockModule],
  controllers: [SalesController, CashSessionsController],
  providers: [SalesService, CashSessionsService],
  exports: [SalesService, CashSessionsService],
})
export class SalesModule {}
