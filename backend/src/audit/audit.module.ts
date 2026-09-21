import { Module } from '@nestjs/common';
import { AuditController } from './audit.controller';
import { AuditService } from './audit.service';

/// Historique global (P0 n°11) : LECTURE du journal que chaque feature écrit
/// dans sa propre transaction (`audit-writer.ts`). Réservé à l'admin.
@Module({
  controllers: [AuditController],
  providers: [AuditService],
})
export class AuditModule {}
