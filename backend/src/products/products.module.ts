import { Module } from '@nestjs/common';
import {
  CategoriesController,
  PricingController,
  ProductsController,
} from './products.controller';

@Module({
  controllers: [ProductsController, CategoriesController, PricingController],
})
export class ProductsModule {}
