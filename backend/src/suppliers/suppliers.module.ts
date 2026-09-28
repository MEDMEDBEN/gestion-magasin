import { Module } from '@nestjs/common';
import {
  SupplierPaymentsController,
  SuppliersController,
} from './suppliers.controller';
import { StockModule } from '../stock/stock.module';
import {
  SupplierReturnsController,
  SupplierReturnsService,
} from './supplier-returns';
import { SuppliersService } from './suppliers.service';

@Module({
  imports: [StockModule],
  controllers: [
    SuppliersController,
    SupplierPaymentsController,
    SupplierReturnsController,
  ],
  providers: [SuppliersService, SupplierReturnsService],
  exports: [SuppliersService],
})
export class SuppliersModule {}
