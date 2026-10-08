import { Module } from '@nestjs/common';
import { ReceptionsModule } from '../receptions/receptions.module';
import { SalesModule } from '../sales/sales.module';
import { ConfreresController } from './confreres.controller';
import { ConfreresService } from './confreres.service';

@Module({
  imports: [SalesModule, ReceptionsModule],
  controllers: [ConfreresController],
  providers: [ConfreresService],
})
export class ConfreresModule {}
