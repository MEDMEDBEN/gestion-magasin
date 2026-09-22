import { Module } from '@nestjs/common';
import {
  CustomerPaymentsController,
  CustomersController,
} from './customers.controller';
import { CustomersService } from './customers.service';

@Module({
  controllers: [CustomersController, CustomerPaymentsController],
  providers: [CustomersService],
  exports: [CustomersService],
})
export class CustomersModule {}
