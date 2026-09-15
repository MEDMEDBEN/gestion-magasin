import { Module } from '@nestjs/common';
import { StockModule } from '../stock/stock.module';
import { CatalogService } from './catalog.service';
import {
  CatalogController,
  CategoriesController,
  PricingController,
  ProductsController,
} from './products.controller';
import { ProductsService } from './products.service';

@Module({
  imports: [StockModule],
  controllers: [
    ProductsController,
    CategoriesController,
    PricingController,
    CatalogController,
  ],
  providers: [ProductsService, CatalogService],
})
export class ProductsModule {}
