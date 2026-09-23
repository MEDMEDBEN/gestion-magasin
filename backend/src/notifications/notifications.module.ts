import { Module } from '@nestjs/common';
import { NotificationsController } from './notifications.controller';
import { NotificationsService } from './notifications.service';

/// Notifications ciblées par rôle (P1 n°16, spec §18). L'ÉCRITURE se fait
/// depuis les features qui déclenchent l'événement, via les méthodes statiques
/// du service, dans LEUR transaction — ce module n'expose que la lecture.
@Module({
  controllers: [NotificationsController],
  providers: [NotificationsService],
})
export class NotificationsModule {}
