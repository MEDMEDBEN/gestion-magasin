import { Module } from '@nestjs/common';
import { CustomersModule } from '../customers/customers.module';
import { ProductsModule } from '../products/products.module';
import { SuppliersModule } from '../suppliers/suppliers.module';
import { ImportsController } from './imports.controller';
import { ImportsService } from './imports.service';

/// Import Excel/CSV : aucune règle propre — chaque ligne passe par le cœur de
/// création de son module (produits, clients, fournisseurs).
@Module({
  imports: [ProductsModule, CustomersModule, SuppliersModule],
  controllers: [ImportsController],
  providers: [ImportsService],
})
export class ImportsModule {}
