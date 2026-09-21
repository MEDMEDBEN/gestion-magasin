import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import { Type } from 'class-transformer';
import {
  ArrayMaxSize,
  ArrayNotEmpty,
  IsArray,
  IsDate,
  IsEnum,
  IsObject,
  IsString,
  IsUUID,
  Length,
  MaxDate,
  ValidateNested,
} from 'class-validator';
import { ErrorCode } from '../../common/error-codes';
import { IsCanonicalUuid } from '../../common/validation';

/// Aligné sur l'enum Prisma `OperationType` (mêmes valeurs backend / DB / Flutter).
export enum SyncOperationTypeDto {
  SALE = 'SALE',
  RECEPTION = 'RECEPTION',
  TRANSFER = 'TRANSFER',
  INVENTORY = 'INVENTORY',
  PURCHASE_ORDER = 'PURCHASE_ORDER',
  QUOTE = 'QUOTE',
  CUSTOMER_PAYMENT = 'CUSTOMER_PAYMENT',
  SUPPLIER_PAYMENT = 'SUPPLIER_PAYMENT',
  CASH_SESSION = 'CASH_SESSION',
  PRODUCT = 'PRODUCT',
  MANUAL = 'MANUAL',
}

/// Sort du contrat de sync (docs/context.md §4). Seuls `CONFIRMEE` et `REJETEE` sont
/// MÉMORISÉS en base : ce sont des résultats définitifs. `NON_TRAITEE` ne l'est jamais —
/// le client garde la mutation en file et la renverra telle quelle.
export enum SyncResultStatusDto {
  CONFIRMEE = 'CONFIRMEE',
  REJETEE = 'REJETEE',
  NON_TRAITEE = 'NON_TRAITEE',
}

/// Plafond de file défini dans docs/context.md (`MAX_PENDING_MUTATIONS`).
export const SYNC_BATCH_MAX = 200;

/// Dérive d'horloge tolérée sur l'horodatage appareil (24 h).
const DEVICE_CLOCK_TOLERANCE_MS = 24 * 60 * 60 * 1000;

export class SyncMutationDto {
  @ApiProperty({
    description:
      'UUID généré par l’appareil, unique et STABLE entre deux tentatives : c’est la clé ' +
      'd’idempotence. Un renvoi ne réapplique jamais la mutation.',
  })
  @IsUUID()
  clientMutationId!: string;

  @ApiProperty({
    description: 'Appareil émetteur (traçabilité).',
    example: 'poste-caisse-01',
  })
  @IsString()
  @Length(1, 100)
  deviceId!: string;

  @ApiProperty({ enum: SyncOperationTypeDto })
  @IsEnum(SyncOperationTypeDto)
  operationType!: SyncOperationTypeDto;

  @ApiProperty({
    description:
      'Corps de l’opération. Sa forme dépend de `operationType` et est validée par le ' +
      'handler serveur correspondant — un payload non conforme est REJETÉ, pas ignoré.',
    type: 'object',
    additionalProperties: true,
  })
  @IsObject()
  payload!: Record<string, unknown>;

  @ApiProperty({
    description:
      'Horodatage de l’appareil. Le serveur rejoue le lot dans cet ordre croissant. ' +
      'Une date ancienne est normale (appareil longtemps hors-ligne) ; une date à plus de ' +
      '24 h dans le futur est refusée — horloge déréglée, ou tentative de forcer l’ordre.',
    example: '2026-09-09T08:12:33.000Z',
  })
  @Type(() => Date)
  @IsDate()
  @MaxDate(() => new Date(Date.now() + DEVICE_CLOCK_TOLERANCE_MS))
  deviceTimestamp!: Date;
}

export class SyncBatchDto {
  @ApiProperty({
    description:
      'Compte AUTEUR des mutations du lot, tel que l’appareil l’a enregistré. Il doit ' +
      'être le porteur de la session qui envoie : sinon RIEN n’est traité (tout repart ' +
      '`NON_TRAITEE`), pour qu’aucune opération ne soit attribuée au mauvais compte ' +
      'sur un poste partagé (changement de compte pendant un envoi).',
  })
  @IsCanonicalUuid()
  authorUserId!: string;

  @ApiProperty({ type: [SyncMutationDto], maxItems: SYNC_BATCH_MAX })
  @IsArray()
  @ArrayNotEmpty()
  @ArrayMaxSize(SYNC_BATCH_MAX)
  @ValidateNested({ each: true })
  @Type(() => SyncMutationDto)
  mutations!: SyncMutationDto[];
}

export class SyncMutationResultDto {
  @ApiProperty() clientMutationId!: string;

  @ApiProperty({ enum: SyncResultStatusDto })
  status!: SyncResultStatusDto;

  @ApiPropertyOptional({
    nullable: true,
    description: 'Entité créée côté serveur si `CONFIRMEE`.',
  })
  entityId?: string | null;

  @ApiPropertyOptional({
    enum: ErrorCode,
    description:
      'Code métier stable — le client s’y réfère, jamais au texte du message.',
  })
  code?: ErrorCode;

  @ApiPropertyOptional({
    description:
      'Motif lisible, à afficher tel quel à l’utilisateur en cas de rejet.',
  })
  reason?: string;

  @ApiPropertyOptional({
    description: 'État serveur après application (ex : projection de stock).',
    type: 'object',
    additionalProperties: true,
  })
  serverState?: Record<string, string>;

  @ApiProperty({
    description:
      'Vrai si le résultat vient de la mémoire d’idempotence : la mutation avait déjà ' +
      'été traitée, rien n’a été réappliqué.',
  })
  alreadyProcessed!: boolean;
}

export class SyncBatchResultDto {
  @ApiProperty({
    description: 'Horloge serveur — référence pour le prochain delta sync.',
  })
  serverTime!: Date;

  @ApiProperty({
    type: [SyncMutationResultDto],
    description:
      'Un résultat par mutation, dans l’ordre de traitement (timestamp appareil croissant). ' +
      'Le client réconcilie sa file sur `clientMutationId`.',
  })
  results!: SyncMutationResultDto[];
}
