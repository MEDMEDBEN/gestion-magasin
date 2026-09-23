import { Controller, Get, Param, Post, Query } from '@nestjs/common';
import {
  ApiBearerAuth,
  ApiOkResponse,
  ApiOperation,
  ApiTags,
} from '@nestjs/swagger';
import {
  AuthenticatedUser,
  CurrentUser,
  RequireFreshAccess,
  RoleCode,
  Roles,
} from '../common/auth.decorators';
import { CanonicalUuidPipe } from '../common/canonical-uuid.pipe';
import {
  NotificationListDto,
  NotificationListQueryDto,
  UnreadCountDto,
} from './dto/notification.dto';
import { NotificationsService } from './notifications.service';

const ALL_ROLES = [RoleCode.ADMIN, RoleCode.VENDEUR, RoleCode.MAGASINIER];

/// Boîte de réception du compte connecté (spec §18).
///
/// Aucune permission particulière : recevoir des alertes fait partie du métier
/// des trois rôles. Ce qui est gardé, c'est le DESTINATAIRE — le serveur ne lit
/// et ne modifie que les notifications du compte qui appelle, l'admin compris.
@ApiTags('Notifications')
@ApiBearerAuth()
@Controller('notifications')
export class NotificationsController {
  constructor(private readonly notifications: NotificationsService) {}

  /// Lecture SENSIBLE : les droits sont relus en base, comme pour le tableau de
  /// bord et l'historique. Sans cela, un compte désactivé ou rétrogradé
  /// continuerait de lire sa boîte — qui cite des documents — pendant la durée
  /// de vie de son access token.
  @Roles(...ALL_ROLES)
  @RequireFreshAccess()
  @Get()
  @ApiOperation({ summary: 'Mes notifications, les plus récentes d’abord' })
  @ApiOkResponse({ type: NotificationListDto })
  list(
    @CurrentUser() user: AuthenticatedUser,
    @Query() query: NotificationListQueryDto,
  ): Promise<NotificationListDto> {
    return this.notifications.list(user, query);
  }

  @Roles(...ALL_ROLES)
  @Post(':id/read')
  @ApiOperation({
    summary: 'Marquer une notification comme lue',
    description:
      'Rejouable : marquer deux fois ne change rien. Rend le nombre de non ' +
      'lues restantes, pour que le badge n’ait pas à être recalculé côté app.',
  })
  @ApiOkResponse({ type: UnreadCountDto })
  markRead(
    @CurrentUser() user: AuthenticatedUser,
    @Param('id', CanonicalUuidPipe) id: string,
  ): Promise<UnreadCountDto> {
    return this.notifications.markRead(user, id);
  }

  @Roles(...ALL_ROLES)
  @Post('read-all')
  @ApiOperation({ summary: 'Tout marquer comme lu' })
  @ApiOkResponse({ type: UnreadCountDto })
  markAllRead(@CurrentUser() user: AuthenticatedUser): Promise<UnreadCountDto> {
    return this.notifications.markAllRead(user);
  }
}
