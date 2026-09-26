import { ApiProperty, ApiPropertyOptional, PickType } from '@nestjs/swagger';
import { Type } from 'class-transformer';
import {
  ArrayMaxSize,
  ArrayNotEmpty,
  IsArray,
  IsIn,
  IsOptional,
  IsString,
  Matches,
  MaxLength,
  ValidateNested,
} from 'class-validator';
import { DAY_MESSAGE, DAY_PATTERN } from '../../common/dto/day-period.dto';
import {
  PaginationMetaDto,
  PaginationQueryDto,
} from '../../common/dto/pagination.dto';
import { ClientGeneratedId, IsCanonicalUuid } from '../../common/validation';
import { CreateSaleDto, CreateSaleLineDto } from './sale.dto';

/// Statuts d'un devis (spec §8quater). `EXPIRE` n'est jamais ÉCRIT en base :
/// un devis non abouti dont la date de validité est passée est LU expiré —
/// sans ordonnanceur à surveiller.
export const QUOTE_STATUSES = [
  'BROUILLON',
  'ENVOYE',
  'ACCEPTE',
  'CONVERTI',
  'REFUSE',
  'EXPIRE',
] as const;
export type QuoteStatus = (typeof QUOTE_STATUSES)[number];

/// Devis : mêmes lignes qu'une vente, mêmes règles de prix (tarif du client,
/// plancher du coût d'achat, remise réservée à l'admin). Aucun paiement, aucun
/// mouvement de stock.
export class CreateQuoteDto {
  @ApiPropertyOptional({
    description:
      'UUID généré par le client : un renvoi ne crée pas un second devis.',
  })
  @ClientGeneratedId()
  id?: string;

  @ApiPropertyOptional({ description: 'Client — absent : devis comptoir.' })
  @IsCanonicalUuid()
  @IsOptional()
  customerId?: string;

  @ApiPropertyOptional({
    example: '2026-10-26',
    description:
      'Dernier jour de validité (AAAA-MM-JJ, jour d’Alger), aujourd’hui ou plus ' +
      'tard. Absent : pas d’échéance. Passé ce jour, le devis est lu `EXPIRE` ' +
      'et ne se convertit plus.',
  })
  @Matches(DAY_PATTERN, { message: DAY_MESSAGE })
  @IsOptional()
  validUntil?: string;

  @ApiPropertyOptional()
  @IsString()
  @MaxLength(500)
  @IsOptional()
  note?: string;

  @ApiProperty({ type: [CreateSaleLineDto] })
  @IsArray()
  @ArrayNotEmpty()
  @ArrayMaxSize(200)
  @ValidateNested({ each: true })
  @Type(() => CreateSaleLineDto)
  lines!: CreateSaleLineDto[];
}

/// Conversion d'un devis ACCEPTÉ en vente : les lignes et le client viennent du
/// devis ; seul l'encaissement est à dire. Mutation d'ARGENT : clé
/// d'idempotence obligatoire, comme `POST /sales`.
export class ConvertQuoteDto extends PickType(CreateSaleDto, [
  'clientMutationId',
  'id',
  'cashSessionId',
  'paidAmount',
  'expectedTotalTtc',
  'dueDate',
] as const) {}

export class QuoteLineDto {
  @ApiProperty() id!: string;
  @ApiProperty() productId!: string;
  @ApiProperty({ example: '12.500' }) quantity!: string;
  @ApiProperty({ description: 'Prix HT promis, en centimes.' })
  unitPriceHt!: number;
  @ApiProperty({ example: '19.00' }) taxRate!: string;
  @ApiProperty() discountAmount!: number;
  @ApiProperty() lineTotalHt!: number;
  @ApiProperty() lineTaxAmount!: number;
  @ApiProperty() lineTotalTtc!: number;
}

export class QuoteDto {
  @ApiProperty() id!: string;
  @ApiProperty({ description: 'Numéro DV-AAAA-NNNNN' }) number!: string;
  @ApiProperty({
    enum: QUOTE_STATUSES,
    description: 'Statut LU : `EXPIRE` si la validité est passée.',
  })
  status!: QuoteStatus;
  @ApiProperty({ nullable: true }) customerId!: string | null;
  @ApiProperty({ nullable: true }) customerName!: string | null;
  @ApiProperty() userId!: string;
  @ApiProperty({ nullable: true, example: '2026-10-26' })
  validUntil!: string | null;
  @ApiProperty() totalHt!: number;
  @ApiProperty() totalTax!: number;
  @ApiProperty() totalTtc!: number;
  @ApiProperty({ nullable: true }) note!: string | null;
  @ApiProperty({
    nullable: true,
    description: 'Vente issue de la conversion.',
  })
  saleId!: string | null;
  @ApiProperty() createdAt!: Date;
  @ApiProperty({ type: [QuoteLineDto] }) lines!: QuoteLineDto[];
}

export class QuoteListQueryDto extends PaginationQueryDto {
  @ApiPropertyOptional({ enum: QUOTE_STATUSES })
  @IsIn(QUOTE_STATUSES)
  @IsOptional()
  status?: QuoteStatus;

  @ApiPropertyOptional() @IsCanonicalUuid() @IsOptional() customerId?: string;
}

export class QuoteListDto {
  @ApiProperty({ type: [QuoteDto] }) data!: QuoteDto[];
  @ApiProperty({ type: PaginationMetaDto }) meta!: PaginationMetaDto;
}
