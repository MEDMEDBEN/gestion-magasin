import { Module } from '@nestjs/common';
import { StockModule } from '../stock/stock.module';
import { CashSessionsController } from './cash-sessions.controller';
import { CashSessionsService } from './cash-sessions.service';
import { SalesController } from './sales.controller';
import { QuotesController } from './quotes.controller';
import { QuotesService } from './quotes.service';
import { SalesService } from './sales.service';
import { SaleReturnsService } from './sale-returns.service';

@Module({
  imports: [StockModule],
  controllers: [SalesController, CashSessionsController, QuotesController],
  providers: [
    SalesService,
    CashSessionsService,
    QuotesService,
    SaleReturnsService,
  ],
  exports: [SalesService, CashSessionsService],
})
export class SalesModule {}
