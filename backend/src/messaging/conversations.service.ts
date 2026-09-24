import { HttpStatus, Injectable } from '@nestjs/common';
import { AuthenticatedUser } from '../common/auth.decorators';
import { BusinessException } from '../common/business.exception';
import { ErrorCode } from '../common/error-codes';
import { Prisma } from '../generated/prisma/client';
import { NotificationsService } from '../notifications/notifications.service';
import { PrismaService } from '../prisma/prisma.service';
import {
  ConversationDto,
  ConversationListDto,
  ConversationListQueryDto,
  CreateConversationDto,
  MessageDto,
  PostMessageDto,
} from './dto/conversation.dto';

type Db = Prisma.TransactionClient;

const CONVERSATION_INCLUDE = {
  participants: {
    include: { user: { select: { id: true, fullName: true } } },
    orderBy: { joinedAt: 'asc' },
  },
} as const;

type ConversationRow = Prisma.ConversationGetPayload<{
  include: typeof CONVERSATION_INCLUDE;
}>;

/// Communication interne (P1 n°17, spec §25).
///
/// Le droit d'accès vient de la PARTICIPATION, pas d'un rôle : un fil dont je
/// ne fais pas partie n'existe pas pour moi, l'admin compris tant qu'il n'y a
/// pas été ajouté. Même principe que la boîte de notifications.
///
/// Volontairement pauvre en fonctions : la spec §25 prévient qu'« une opération
/// métier structurée ne doit jamais être remplacée par un message ». Demander
/// 20 LED reste une demande de transfert ; ce module sert à la question et à la
/// consigne. Pas de pièce jointe, pas d'édition, pas de suppression (règle 7).
@Injectable()
export class ConversationsService {
  constructor(private readonly prisma: PrismaService) {}

  async create(
    dto: CreateConversationDto,
    user: AuthenticatedUser,
  ): Promise<ConversationDto> {
    // Le créateur est TOUJOURS participant : on ne lance pas un fil qu'on ne
    // lit pas. Doublons écartés, et soi-même retiré de la liste envoyée.
    const others = [...new Set(dto.participantIds)].filter(
      (id) => id !== user.id,
    );
    if (others.length === 0) {
      throw new BusinessException(
        ErrorCode.VALIDATION_FAILED,
        'participantIds : choisissez au moins un autre membre',
        HttpStatus.UNPROCESSABLE_ENTITY,
      );
    }
    const active = await this.prisma.user.findMany({
      where: { id: { in: others }, isActive: true },
      select: { id: true },
    });
    if (active.length !== others.length) {
      throw new BusinessException(
        ErrorCode.VALIDATION_FAILED,
        'participantIds : membre introuvable ou désactivé',
        HttpStatus.UNPROCESSABLE_ENTITY,
      );
    }

    const conversation = await this.prisma.$transaction(async (tx) => {
      const created = await tx.conversation.create({
        include: CONVERSATION_INCLUDE,
        data: {
          subject: dto.subject,
          createdById: user.id,
          participants: {
            create: [
              // Le créateur a lu son propre message par construction.
              { userId: user.id, lastReadAt: new Date() },
              ...active.map(({ id }) => ({ userId: id })),
            ],
          },
        },
      });
      await this.appendMessage(tx, created, user, dto.body);
      return created;
    });
    return ConversationsService.toDto(conversation, 0);
  }

  /// À qui je peux écrire : les membres ACTIFS, moi excepté. Identifiant et nom
  /// seulement — la liste des comptes (`/users`) reste fermée aux non-admins,
  /// et c'est pourtant le magasinier qui a le plus besoin de poser une question.
  async recipients(
    user: AuthenticatedUser,
  ): Promise<{ id: string; fullName: string }[]> {
    return this.prisma.user.findMany({
      where: { isActive: true, id: { not: user.id } },
      select: { id: true, fullName: true },
      orderBy: { fullName: 'asc' },
    });
  }

  /// MES fils, le plus récemment animé en tête, avec mes non-lus.
  async findAll(
    user: AuthenticatedUser,
    query: ConversationListQueryDto,
  ): Promise<ConversationListDto> {
    const where: Prisma.ConversationWhereInput = {
      participants: { some: { userId: user.id } },
      ...(query.includeClosed ? {} : { closedAt: null }),
    };
    const [rows, total] = await Promise.all([
      this.prisma.conversation.findMany({
        where,
        include: CONVERSATION_INCLUDE,
        orderBy: [{ lastMessageAt: 'desc' }, { id: 'desc' }],
        skip: (query.page - 1) * query.limit,
        take: query.limit,
      }),
      this.prisma.conversation.count({ where }),
    ]);
    const unread = await this.unreadByConversation(
      user,
      rows.map((r) => r.id),
    );
    return {
      data: rows.map((row) =>
        ConversationsService.toDto(row, unread.get(row.id) ?? 0),
      ),
      meta: { page: query.page, limit: query.limit, total },
    };
  }

  /// Détail d'un fil AVEC ses messages. L'ouvrir vaut lecture : `lastReadAt`
  /// avance, donc les non-lus tombent à zéro — c'est l'acte de l'ouvrir qui
  /// fait foi, pas un bouton « marquer lu » que personne ne presse.
  async findOne(id: string, user: AuthenticatedUser): Promise<ConversationDto> {
    const conversation = await this.readable(id, user);
    // Instant saisi AVANT la lecture : un message arrivé pendant la requête ne
    // doit pas être marqué lu sans avoir été affiché — il disparaîtrait du
    // compteur sans que personne ne l'ait vu.
    const readAt = new Date();
    const messages = await this.prisma.message.findMany({
      where: { conversationId: id },
      include: { author: { select: { fullName: true } } },
      // Borne : un fil très ancien ne se charge pas d'un coup. Les plus
      // RÉCENTS d'abord, puis remis dans l'ordre de lecture.
      orderBy: [{ createdAt: 'desc' }, { id: 'desc' }],
      take: 200,
    });
    messages.reverse();
    await this.prisma.conversationParticipant.updateMany({
      where: { conversationId: id, userId: user.id },
      data: { lastReadAt: readAt },
    });
    // Ouvrir le fil SOLDE aussi ses alertes : sans cela, dix messages lus
    // laissaient dix notifications au compteur, et l'utilisateur devait aller
    // les effacer ailleurs (spec §18 : une alerte est faite pour être traitée).
    await this.prisma.notification.updateMany({
      where: {
        userId: user.id,
        operationType: 'CONVERSATION',
        operationId: id,
        isRead: false,
      },
      data: { isRead: true, readAt },
    });
    return {
      ...ConversationsService.toDto(conversation, 0),
      messages: messages.map((m): MessageDto => ({
        id: m.id,
        authorId: m.authorId,
        authorName: m.author.fullName,
        body: m.body,
        createdAt: m.createdAt.toISOString(),
      })),
    };
  }

  async postMessage(
    id: string,
    dto: PostMessageDto,
    user: AuthenticatedUser,
  ): Promise<ConversationDto> {
    const conversation = await this.readable(id, user);
    await this.prisma.$transaction((tx) =>
      this.appendMessage(tx, conversation, user, dto.body),
    );
    return this.findOne(id, user);
  }

  /// Clore un fil : son auteur ou un admin. Rien n'est supprimé (règle 7), le
  /// fil reste consultable.
  async close(id: string, user: AuthenticatedUser): Promise<ConversationDto> {
    const conversation = await this.readable(id, user);
    if (conversation.closedAt) return this.findOne(id, user);
    if (conversation.createdById !== user.id && !user.roles.includes('ADMIN')) {
      throw new BusinessException(
        ErrorCode.FORBIDDEN_ROLE,
        'Seul l’auteur du fil ou un administrateur peut le clore',
        HttpStatus.FORBIDDEN,
      );
    }
    // `updateMany` conditionnel : deux clôtures simultanées n'écrasent pas la
    // première — qui a clos, et quand, ne change plus.
    await this.prisma.conversation.updateMany({
      where: { id, closedAt: null },
      data: { closedAt: new Date(), closedById: user.id },
    });
    return this.findOne(id, user);
  }

  /// Écrit le message, remonte le fil et prévient les AUTRES participants —
  /// le tout dans la transaction de l'appelant : pas de message sans alerte,
  /// pas d'alerte sans message.
  private async appendMessage(
    tx: Db,
    conversation: ConversationRow,
    user: AuthenticatedUser,
    body: string,
  ): Promise<void> {
    // Le fil est remonté SOUS CONDITION qu'il soit encore ouvert : c'est cette
    // écriture conditionnelle, dans la transaction, qui interdit à une clôture
    // concurrente de laisser passer un message. Un contrôle lu avant la
    // transaction laisserait la fenêtre ouverte.
    const reopened = await tx.conversation.updateMany({
      where: { id: conversation.id, closedAt: null },
      data: { lastMessageAt: new Date() },
    });
    if (reopened.count === 0) {
      throw new BusinessException(
        ErrorCode.INVALID_STATE_TRANSITION,
        'Fil clos : rouvrez-en un nouveau plutôt que de réécrire dedans',
        HttpStatus.CONFLICT,
      );
    }
    await tx.message.create({
      data: { conversationId: conversation.id, authorId: user.id, body },
    });
    await NotificationsService.notifyUsers(
      tx,
      conversation.participants
        .map((p) => p.userId)
        .filter((userId) => userId !== user.id),
      {
        type: 'MESSAGE',
        title: conversation.subject,
        // Le message lui-même n'est PAS recopié dans l'alerte : elle survivrait
        // au fil et échapperait au cloisonnement par participation.
        body: 'Nouveau message',
        operationType: 'CONVERSATION',
        operationId: conversation.id,
      },
    );
  }

  /// Un fil dont je ne suis pas participant n'est pas « interdit » : il
  /// n'existe pas pour moi. Le 404 ne dit pas qu'il existe ailleurs.
  private async readable(
    id: string,
    user: AuthenticatedUser,
  ): Promise<ConversationRow> {
    const conversation = await this.prisma.conversation.findFirst({
      where: { id, participants: { some: { userId: user.id } } },
      include: CONVERSATION_INCLUDE,
    });
    if (!conversation) {
      throw new BusinessException(
        ErrorCode.NOT_FOUND,
        'Conversation introuvable',
        HttpStatus.NOT_FOUND,
      );
    }
    return conversation;
  }

  /// Non-lus par fil, en UNE requête : les messages postés après ma dernière
  /// lecture, les miens exclus (on ne se notifie pas soi-même).
  private async unreadByConversation(
    user: AuthenticatedUser,
    ids: string[],
  ): Promise<Map<string, number>> {
    if (ids.length === 0) return new Map();
    const seen = await this.prisma.conversationParticipant.findMany({
      where: { userId: user.id, conversationId: { in: ids } },
      select: { conversationId: true, lastReadAt: true },
    });
    const counts = await this.prisma.message.groupBy({
      by: ['conversationId'],
      where: {
        conversationId: { in: ids },
        authorId: { not: user.id },
        OR: seen.map((s) => ({
          conversationId: s.conversationId,
          ...(s.lastReadAt ? { createdAt: { gt: s.lastReadAt } } : {}),
        })),
      },
      _count: { _all: true },
    });
    return new Map(counts.map((c) => [c.conversationId, c._count._all]));
  }

  private static toDto(row: ConversationRow, unread: number): ConversationDto {
    return {
      id: row.id,
      subject: row.subject,
      createdById: row.createdById,
      participants: row.participants.map((p) => ({
        userId: p.userId,
        fullName: p.user.fullName,
      })),
      closedAt: row.closedAt?.toISOString() ?? null,
      lastMessageAt: row.lastMessageAt.toISOString(),
      unread,
      createdAt: row.createdAt.toISOString(),
    };
  }
}
