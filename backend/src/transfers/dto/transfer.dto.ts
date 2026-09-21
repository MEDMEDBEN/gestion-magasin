import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import { Transform, Type } from 'class-transformer';
import {
  ArrayMaxSize,
  ArrayNotEmpty,
  IsArray,
  IsBoolean,
  IsEnum,
  IsOptional,
  IsString,
  Matches,
  MaxLength,
  ValidateNested,
} from 'class-validator';
import {
  PaginationMetaDto,
  PaginationQueryDto,
} from '../../common/dto/pagination.dto';
import { ClientMutationId } from '../../common/idempotency';
import {
  booleanQuery,
  ClientGeneratedId,
  IsCanonicalUuid,
} from '../../common/validation';

/// Quantités : décimales à 3 décimales au plus (règle 10), transportées en
/// CHAÎNE pour ne jamais passer par un flottant.
const QUANTITY_PATTERN = /^\d{1,11}(\.\d{1,3})?$/;

export enum PriorityDto {
  BASSE = 'BASSE',
  NORMALE = 'NORMALE',
  HAUTE = 'HAUTE',
  URGENTE = 'URGENTE',
}

/// Issue d'un transfert abandonné : REFUSEE vient du dépôt, ANNULEE du demandeur.
export enum TransferClosureDto {
  REFUSEE = 'REFUSEE',
  ANNULEE = 'ANNULEE',
}

export class TransferLineInputDto {
  @ApiProperty() @IsCanonicalUuid() productId!: string;

  @ApiProperty({
    example: '20.000',
    description: 'Quantité demandée (décimale, 3 décimales au plus).',
    pattern: '^\\d{1,11}(\\.\\d{1,3})?$',
  })
  @IsString()
  @MaxLength(20)
  @Matches(QUANTITY_PATTERN, {
    message: 'quantity : décimale à 3 décimales au plus attendue',
  })
  quantity!: string;
}

export class CreateTransferDto {
  @ApiPropertyOptional({ description: 'UUID généré par le client.' })
  @ClientGeneratedId()
  id?: string;

  @ApiPropertyOptional({
    description:
      'Origine. Absente = le DÉPÔT (le périmètre est 1 magasin + 1 dépôt).',
  })
  @IsCanonicalUuid()
  @IsOptional()
  fromLocationId?: string;

  @ApiPropertyOptional({
    description: 'Destination. Absente = le MAGASIN.',
  })
  @IsCanonicalUuid()
  @IsOptional()
  toLocationId?: string;

  @ApiPropertyOptional({ enum: PriorityDto, default: PriorityDto.NORMALE })
  @IsEnum(PriorityDto)
  @IsOptional()
  priority?: PriorityDto;

  @ApiPropertyOptional()
  @Transform(({ value }: { value: unknown }) =>
    typeof value === 'string' ? value.trim() || null : value,
  )
  @IsString()
  @MaxLength(500)
  @IsOptional()
  comment?: string | null;

  @ApiProperty({ type: [TransferLineInputDto] })
  @IsArray()
  @ArrayNotEmpty()
  @ArrayMaxSize(200)
  @ValidateNested({ each: true })
  @Type(() => TransferLineInputDto)
  lines!: TransferLineInputDto[];

  /// Une demande renvoyée deux fois (réseau coupé, double clic) ne doit pas
  /// devenir deux demandes : clé obligatoire, comme sur toute création suivie.
  @ClientMutationId() clientMutationId!: string;
}

export class PrepareTransferLineDto {
  @ApiProperty() @IsCanonicalUuid() productId!: string;

  @ApiProperty({
    example: '18.000',
    description:
      'Préparation PARTIELLE autorisée : quantité réellement préparée ' +
      '(0 pour une ligne finalement introuvable). Jamais plus que le demandé.',
    pattern: '^\\d{1,11}(\\.\\d{1,3})?$',
  })
  @IsString()
  @MaxLength(20)
  @Matches(QUANTITY_PATTERN, {
    message: 'preparedQuantity : décimale à 3 décimales au plus attendue',
  })
  preparedQuantity!: string;
}

export class PrepareTransferDto {
  @ApiProperty({ type: [PrepareTransferLineDto] })
  @IsArray()
  @ArrayNotEmpty()
  @ArrayMaxSize(200)
  @ValidateNested({ each: true })
  @Type(() => PrepareTransferLineDto)
  lines!: PrepareTransferLineDto[];

  @ApiPropertyOptional({
    default: true,
    description:
      'false = préparation en cours (EN_PREPARATION), reprise possible plus ' +
      'tard depuis le mobile. true = terminée (PREPAREE), prête à expédier.',
  })
  @IsBoolean()
  @IsOptional()
  done?: boolean;
}

export class ReceiveTransferLineDto {
  @ApiProperty() @IsCanonicalUuid() productId!: string;

  @ApiProperty({
    example: '18.000',
    description:
      'Quantité RÉELLEMENT arrivée au magasin, jamais plus que l’expédiée. ' +
      'Le manquant retourne au dépôt pour y être constaté (perte, casse).',
    pattern: '^\\d{1,11}(\\.\\d{1,3})?$',
  })
  @IsString()
  @MaxLength(20)
  @Matches(QUANTITY_PATTERN, {
    message: 'receivedQuantity : décimale à 3 décimales au plus attendue',
  })
  receivedQuantity!: string;
}

export class ReceiveTransferDto {
  @ApiPropertyOptional({
    type: [ReceiveTransferLineDto],
    description: 'Absent = tout ce qui a été expédié est arrivé.',
  })
  @IsArray()
  @ArrayMaxSize(200)
  @ValidateNested({ each: true })
  @Type(() => ReceiveTransferLineDto)
  @IsOptional()
  lines?: ReceiveTransferLineDto[];
}

export class CloseTransferDto {
  @ApiProperty({
    enum: TransferClosureDto,
    description:
      'REFUSEE : le dépôt ne suivra pas (ADMIN ou MAGASINIER). ANNULEE : le ' +
      'demandeur renonce (ADMIN, ou le vendeur auteur de la demande).',
  })
  @IsEnum(TransferClosureDto)
  status!: TransferClosureDto;
}

export class TransferLineDto {
  @ApiProperty() id!: string;
  @ApiProperty() productId!: string;
  @ApiProperty({ example: '20.000' }) requestedQuantity!: string;
  @ApiProperty({ example: '18.000' }) preparedQuantity!: string;
  @ApiProperty({ example: '18.000' }) shippedQuantity!: string;
  @ApiProperty({ example: '18.000' }) receivedQuantity!: string;
}

export class TransferDto {
  @ApiProperty() id!: string;
  @ApiProperty({ example: 'TRF-2026-00001' }) number!: string;
  @ApiProperty({
    example: 'DEMANDEE',
    description:
      'DEMANDEE → ACCEPTEE → EN_PREPARATION → PREPAREE → EN_TRANSIT → RECUE (+ REFUSEE, ANNULEE)',
  })
  status!: string;
  @ApiProperty({ enum: PriorityDto }) priority!: PriorityDto;
  @ApiProperty() fromLocationId!: string;
  @ApiProperty() toLocationId!: string;
  @ApiProperty() requestedById!: string;
  @ApiProperty({ nullable: true }) preparedById!: string | null;
  @ApiProperty({ nullable: true }) receivedById!: string | null;
  @ApiProperty() requestedAt!: Date;
  @ApiProperty({ nullable: true }) preparedAt!: Date | null;
  @ApiProperty({ nullable: true }) shippedAt!: Date | null;
  @ApiProperty({ nullable: true }) receivedAt!: Date | null;
  @ApiProperty({ nullable: true }) comment!: string | null;
  @ApiProperty() updatedAt!: Date;
  @ApiProperty({ type: [TransferLineDto] }) lines!: TransferLineDto[];
}

export class TransferListQueryDto extends PaginationQueryDto {
  @ApiPropertyOptional({
    description:
      'Statut exact, ou `EN_COURS` pour tout ce qui n’est pas soldé.',
  })
  @IsString()
  @MaxLength(20)
  @IsOptional()
  status?: string;

  @ApiPropertyOptional({ description: 'Seulement mes propres demandes.' })
  @Transform(booleanQuery)
  @IsBoolean()
  @IsOptional()
  mine?: boolean;
}

export class TransferListDto {
  @ApiProperty({ type: [TransferDto] }) data!: TransferDto[];
  @ApiProperty({ type: PaginationMetaDto }) meta!: PaginationMetaDto;
}
