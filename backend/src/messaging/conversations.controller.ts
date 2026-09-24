import { Body, Controller, Get, Param, Post, Query } from '@nestjs/common';
import { Throttle } from '@nestjs/throttler';
import {
  ApiBearerAuth,
  ApiCreatedResponse,
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
import { ConversationsService } from './conversations.service';
import {
  ConversationDto,
  ConversationListDto,
  ConversationListQueryDto,
  ConversationRecipientDto,
  CreateConversationDto,
  PostMessageDto,
} from './dto/conversation.dto';

const ALL_ROLES = [RoleCode.ADMIN, RoleCode.VENDEUR, RoleCode.MAGASINIER];

/// Communication interne (spec §25). Aucune permission : échanger fait partie
/// du métier des trois rôles. Ce qui est gardé, c'est la PARTICIPATION — un fil
/// dont je ne fais pas partie répond 404, l'admin compris.
///
/// Lecture sensible : les droits sont relus en base, comme pour les
/// notifications — un compte désactivé cesse aussitôt de lire ses fils.
@ApiTags('Communication interne')
@ApiBearerAuth()
@Controller('conversations')
export class ConversationsController {
  constructor(private readonly conversations: ConversationsService) {}

  @Roles(...ALL_ROLES)
  @RequireFreshAccess()
  @Get()
  @ApiOperation({
    summary: 'Mes fils, le plus récemment animé en tête',
    description:
      'Les fils clos sont exclus ; `includeClosed=true` les rend. `unread` = ' +
      'messages postés après ma dernière lecture, les miens exclus.',
  })
  @ApiOkResponse({ type: ConversationListDto })
  findAll(
    @CurrentUser() user: AuthenticatedUser,
    @Query() query: ConversationListQueryDto,
  ): Promise<ConversationListDto> {
    return this.conversations.findAll(user, query);
  }

  /// Annuaire MINIMAL des destinataires possibles : identifiant et nom, rien
  /// d'autre. `/users` est réservé à l'admin et expose bien plus (email, rôles,
  /// état du compte) — sans cette route, deux rôles sur trois ne pouvaient pas
  /// ouvrir un fil, alors que le contrôleur les y autorise (audit sécurité).
  ///
  /// Déclarée AVANT `@Get(':id')`, sinon « recipients » serait pris pour un id.
  @Roles(...ALL_ROLES)
  @RequireFreshAccess()
  @Get('recipients')
  @ApiOperation({
    summary: 'Membres actifs à qui écrire (id et nom seulement)',
  })
  @ApiOkResponse({ type: [ConversationRecipientDto] })
  recipients(
    @CurrentUser() user: AuthenticatedUser,
  ): Promise<ConversationRecipientDto[]> {
    return this.conversations.recipients(user);
  }

  @Roles(...ALL_ROLES)
  @RequireFreshAccess()
  @Get(':id')
  @ApiOperation({
    summary: 'Un fil et ses messages',
    description:
      'L’ouvrir vaut LECTURE : les non-lus de ce fil tombent à zéro. ' +
      'Un fil dont je ne suis pas participant répond 404.',
  })
  @ApiOkResponse({ type: ConversationDto })
  findOne(
    @CurrentUser() user: AuthenticatedUser,
    @Param('id', CanonicalUuidPipe) id: string,
  ): Promise<ConversationDto> {
    return this.conversations.findOne(id, user);
  }

  // Débit bridé : un message écrit une alerte PAR participant (jusqu'à 20).
  // La limite globale est par IP — tout le magasin la partage — donc elle ne
  // protège pas la boîte d'un collègue (audit sécurité).
  @Throttle({ default: { ttl: 60_000, limit: 20 } })
  @Roles(...ALL_ROLES)
  @Post()
  @ApiOperation({
    summary: 'Ouvrir un fil avec un premier message',
    description:
      'Un fil vide n’informe personne : le premier message est obligatoire. ' +
      'Rappel de la spec §25 : une demande de marchandise se fait par une ' +
      'demande de transfert, pas par un message.',
  })
  @ApiCreatedResponse({ type: ConversationDto })
  create(
    @CurrentUser() user: AuthenticatedUser,
    @Body() dto: CreateConversationDto,
  ): Promise<ConversationDto> {
    return this.conversations.create(dto, user);
  }

  @Throttle({ default: { ttl: 60_000, limit: 60 } })
  @Roles(...ALL_ROLES)
  @Post(':id/messages')
  @ApiOperation({ summary: 'Répondre dans un fil' })
  @ApiCreatedResponse({ type: ConversationDto })
  postMessage(
    @CurrentUser() user: AuthenticatedUser,
    @Param('id', CanonicalUuidPipe) id: string,
    @Body() dto: PostMessageDto,
  ): Promise<ConversationDto> {
    return this.conversations.postMessage(id, dto, user);
  }

  @Roles(...ALL_ROLES)
  @Post(':id/close')
  @ApiOperation({
    summary: 'Clore un fil (son auteur ou un administrateur)',
    description:
      'Rien n’est supprimé : le fil reste consultable, en lecture seule.',
  })
  @ApiOkResponse({ type: ConversationDto })
  close(
    @CurrentUser() user: AuthenticatedUser,
    @Param('id', CanonicalUuidPipe) id: string,
  ): Promise<ConversationDto> {
    return this.conversations.close(id, user);
  }
}
