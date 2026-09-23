import { Injectable } from '@nestjs/common';
import { AuthenticatedUser, RoleCode } from '../common/auth.decorators';
import { parseSort } from '../common/dto/pagination.dto';
import {
  NotificationType,
  OperationType,
  Prisma,
  Priority,
} from '../generated/prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import {
  NotificationDto,
  NotificationListDto,
  NotificationListQueryDto,
} from './dto/notification.dto';

type Db = Prisma.TransactionClient;

/// Ce qu'une opération veut faire savoir. Le `lien` (operationType/Id) est
/// ce qui rend la notification ACTIONNABLE : sans lui, elle informe sans
/// permettre d'agir (spec §18).
export interface NotifyInput {
  type: NotificationType;
  title: string;
  body?: string | null;
  priority?: Priority;
  operationType?: OperationType;
  operationId?: string;
}

const SORT_FIELDS = ['createdAt'] as const;

/// Notifications ciblées par rôle (spec §18).
///
/// Écrites DANS la transaction de l'opération qui les déclenche : une demande
/// au dépôt et l'alerte du magasinier tombent ensemble, ou pas du tout. Une
/// notification orpheline (l'opération a échoué) enverrait l'équipe chercher
/// un document qui n'existe pas.
///
/// Personne n'est notifié de sa PROPRE action : il vient de la faire.
@Injectable()
export class NotificationsService {
  constructor(private readonly prisma: PrismaService) {}

  /// Prévient tous les membres ACTIFS portant l'un de ces rôles, sauf l'auteur.
  static async notifyRoles(
    tx: Db,
    roles: RoleCode[],
    input: NotifyInput,
    exceptUserId?: string,
  ): Promise<void> {
    const recipients = await tx.user.findMany({
      where: {
        id: exceptUserId ? { not: exceptUserId } : undefined,
        roles: { some: { code: { in: roles } } },
      },
      select: { id: true },
    });
    await NotificationsService.notifyUsers(
      tx,
      recipients.map((u) => u.id),
      input,
    );
  }

  /// Prévient des membres nommés (ex. l'auteur d'une demande, quand sa
  /// marchandise est prête). Une liste vide n'écrit rien.
  ///
  /// Le compte ACTIF est vérifié ICI, pour les deux appelants : un compte
  /// désactivé ne doit pas se réveiller, le jour où on le réactive, avec des
  /// alertes périmées sur des documents depuis longtemps traités.
  static async notifyUsers(
    tx: Db,
    userIds: string[],
    input: NotifyInput,
  ): Promise<void> {
    const unique = [...new Set(userIds)];
    if (unique.length === 0) return;
    const active = await tx.user.findMany({
      where: { id: { in: unique }, isActive: true },
      select: { id: true },
    });
    if (active.length === 0) return;
    await tx.notification.createMany({
      data: active.map(({ id: userId }) => ({
        userId,
        type: input.type,
        title: input.title,
        body: input.body ?? null,
        priority: input.priority ?? 'NORMALE',
        operationType: input.operationType ?? null,
        operationId: input.operationId ?? null,
      })),
    });
  }

  /// MES notifications. Le destinataire est le compte connecté, jamais un
  /// paramètre : personne ne lit la boîte d'un collègue, admin compris.
  async list(
    user: AuthenticatedUser,
    query: NotificationListQueryDto,
  ): Promise<NotificationListDto> {
    const { page, limit } = query;
    const where: Prisma.NotificationWhereInput = {
      userId: user.id,
      ...(query.unreadOnly && { isRead: false }),
    };
    const [rows, total, unread] = await Promise.all([
      this.prisma.notification.findMany({
        where,
        // Départiteur `id` : deux alertes de la même opération partagent la
        // milliseconde, et sans lui leur ordre — donc la pagination — varie
        // d'un appel à l'autre.
        orderBy: [
          parseSort(query.sort, SORT_FIELDS, { createdAt: 'desc' }),
          { id: 'desc' },
        ],
        skip: (page - 1) * limit,
        take: limit,
      }),
      this.prisma.notification.count({ where }),
      this.prisma.notification.count({
        where: { userId: user.id, isRead: false },
      }),
    ]);
    return {
      data: rows.map(NotificationsService.toDto),
      meta: { page, limit, total },
      unread,
    };
  }

  /// Marque comme lue. Le `userId` est dans le `where` : une notification qui
  /// n'est pas la mienne n'est pas « interdite », elle n'existe pas pour moi —
  /// et le compteur ne bouge pas.
  async markRead(
    user: AuthenticatedUser,
    id: string,
  ): Promise<{ unread: number }> {
    await this.prisma.notification.updateMany({
      where: { id, userId: user.id, isRead: false },
      data: { isRead: true, readAt: new Date() },
    });
    return this.unreadCount(user);
  }

  async markAllRead(user: AuthenticatedUser): Promise<{ unread: number }> {
    await this.prisma.notification.updateMany({
      where: { userId: user.id, isRead: false },
      data: { isRead: true, readAt: new Date() },
    });
    await this.purgeOld(user);
    return this.unreadCount(user);
  }

  /// Rétention : les alertes LUES de plus de 90 jours sont effacées.
  ///
  /// Purge opportuniste, au moment où l'utilisateur fait le ménage lui-même :
  /// pas d'ordonnanceur à surveiller, et la table ne grossit pas sans fin. Une
  /// notification n'est pas une pièce comptable — l'opération, elle, reste dans
  /// l'historique (règle 7), c'est lui qui fait foi.
  private async purgeOld(user: AuthenticatedUser): Promise<void> {
    const limit = new Date(Date.now() - 90 * 24 * 3600 * 1000);
    await this.prisma.notification.deleteMany({
      where: { userId: user.id, isRead: true, createdAt: { lt: limit } },
    });
  }

  private async unreadCount(
    user: AuthenticatedUser,
  ): Promise<{ unread: number }> {
    return {
      unread: await this.prisma.notification.count({
        where: { userId: user.id, isRead: false },
      }),
    };
  }

  static toDto(row: {
    id: string;
    type: NotificationType;
    priority: Priority;
    title: string;
    body: string | null;
    isRead: boolean;
    readAt: Date | null;
    operationType: OperationType | null;
    operationId: string | null;
    createdAt: Date;
  }): NotificationDto {
    return {
      id: row.id,
      type: row.type,
      priority: row.priority,
      title: row.title,
      body: row.body,
      isRead: row.isRead,
      readAt: row.readAt?.toISOString() ?? null,
      operationType: row.operationType,
      operationId: row.operationId,
      createdAt: row.createdAt.toISOString(),
    };
  }
}

/// Rôles destinataires par nature d'événement — au même endroit pour qu'une
/// alerte ne parte jamais « à tout le monde » par distraction.
export const NOTIFY_DEPOT = [RoleCode.MAGASINIER, RoleCode.ADMIN];
export const NOTIFY_MAGASIN = [RoleCode.VENDEUR, RoleCode.ADMIN];
