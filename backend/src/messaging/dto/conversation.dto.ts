import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import { Transform } from 'class-transformer';
import {
  ArrayMaxSize,
  ArrayMinSize,
  IsArray,
  IsBoolean,
  IsOptional,
  IsString,
  MaxLength,
  MinLength,
} from 'class-validator';
import {
  PaginationMetaDto,
  PaginationQueryDto,
} from '../../common/dto/pagination.dto';
import { booleanQuery, IsCanonicalUuid } from '../../common/validation';

const trim = ({ value }: { value: unknown }) =>
  typeof value === 'string' ? value.trim() : value;

/// Destinataire possible : le STRICT minimum pour choisir un nom dans une
/// liste. Pas d'email, pas de rôle, pas d'état de compte — `/users` reste
/// réservé à l'admin.
export class ConversationRecipientDto {
  @ApiProperty() id!: string;
  @ApiProperty() fullName!: string;
}

export class CreateConversationDto {
  // Pas d'`id` fourni par le client : la messagerie n'est pas dans le contrat
  // de sync hors-ligne, et un identifiant déjà pris répondait 409 là où un
  // identifiant libre répond 201 — de quoi deviner qu'un fil existe (audit).
  @ApiProperty({ example: 'Rupture sur les câbles 2,5 mm²' })
  @Transform(trim)
  @IsString()
  @MinLength(2)
  @MaxLength(120)
  subject!: string;

  @ApiProperty({
    type: [String],
    description:
      'Membres du fil, en plus de vous. Au moins un — un fil avec soi-même ' +
      'n’a pas d’objet.',
  })
  @IsArray()
  @ArrayMinSize(1)
  @ArrayMaxSize(20)
  @IsCanonicalUuid({ each: true })
  participantIds!: string[];

  @ApiProperty({
    description: 'Premier message : un fil vide n’informe personne.',
  })
  @Transform(trim)
  @IsString()
  @MinLength(1)
  @MaxLength(2000)
  body!: string;
}

export class PostMessageDto {
  @ApiProperty({ example: 'Il en reste 3 au dépôt, je te les prépare.' })
  @Transform(trim)
  @IsString()
  @MinLength(1)
  @MaxLength(2000)
  body!: string;
}

export class ConversationListQueryDto extends PaginationQueryDto {
  @ApiPropertyOptional({
    description: 'Inclure les fils clos (exclus par défaut).',
  })
  // `booleanQuery` : le MÊME décodage que partout ailleurs. Une comparaison
  // à la chaîne « true » ignorait silencieusement `1` ou `TRUE`.
  @Transform(booleanQuery)
  @IsBoolean()
  @IsOptional()
  includeClosed?: boolean;
}

export class MessageDto {
  @ApiProperty() id!: string;
  @ApiProperty() authorId!: string;
  @ApiProperty() authorName!: string;
  @ApiProperty() body!: string;
  @ApiProperty() createdAt!: string;
}

export class ConversationParticipantDto {
  @ApiProperty() userId!: string;
  @ApiProperty() fullName!: string;
}

export class ConversationDto {
  @ApiProperty() id!: string;
  @ApiProperty() subject!: string;
  @ApiProperty() createdById!: string;
  @ApiProperty({ type: [ConversationParticipantDto] })
  participants!: ConversationParticipantDto[];
  @ApiProperty({ nullable: true }) closedAt!: string | null;
  @ApiProperty() lastMessageAt!: string;
  @ApiProperty({
    description:
      'Messages non lus PAR MOI (les miens n’en font jamais partie).',
  })
  unread!: number;
  @ApiPropertyOptional({
    type: [MessageDto],
    description: 'Présents sur le détail d’un fil, absents de la liste.',
  })
  messages?: MessageDto[];
  @ApiProperty() createdAt!: string;
}

export class ConversationListDto {
  @ApiProperty({ type: [ConversationDto] }) data!: ConversationDto[];
  @ApiProperty({ type: PaginationMetaDto }) meta!: PaginationMetaDto;
}
