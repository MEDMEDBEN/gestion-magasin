import { Module } from '@nestjs/common';
import { ConversationsController } from './conversations.controller';
import { ConversationsService } from './conversations.service';

/// Communication interne (P1 n°17, spec §25) : fils de discussion entre
/// membres. Aucun stock, aucun argent — et volontairement pauvre en fonctions,
/// pour qu'un message ne remplace jamais une opération métier structurée.
@Module({
  controllers: [ConversationsController],
  providers: [ConversationsService],
})
export class MessagingModule {}
