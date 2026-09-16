import { ClientMutationId } from '../../common/idempotency';
import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import { Type } from 'class-transformer';
import {
  PaginationMetaDto,
  PaginationQueryDto,
} from '../../common/dto/pagination.dto';
import {
  ArrayMaxSize,
  ArrayNotEmpty,
  IsArray,
  IsInt,
  IsOptional,
  IsString,
  Max,
  MaxLength,
  Min,
  ValidateNested,
} from 'class-validator';
import { IsCanonicalUuid } from '../../common/validation';

/// Borne des montants en centimes : colonnes `Int` PostgreSQL (≈ 21 M DA).
export const MAX_MONEY = 2_000_000_000;

export enum SaleTypeDto {
  TICKET = 'TICKET',
  FACTURE = 'FACTURE',
}

export enum PaymentMethodDto {
  ESPECES = 'ESPECES',
  CHEQUE = 'CHEQUE',
  VIREMENT = 'VIREMENT',
  CARTE = 'CARTE',
  AUTRE = 'AUTRE',
}

export class CreateSaleLineDto {
  @ApiProperty() @IsCanonicalUuid() productId!: string;

  @ApiProperty({
    example: '12.500',
    description: 'Quantité décimale positive, en chaîne.',
  })
  @IsString()
  @MaxLength(20)
  quantity!: string;

  @ApiPropertyOptional({
    description:
      'Remise en centimes sur la ligne. Réservée à l’ADMIN (`sale.discount`) — ' +
      'le vendeur n’applique aucune remise libre.',
  })
  @IsInt()
  @Min(0)
  @Max(MAX_MONEY)
  @IsOptional()
  discountAmount?: number;
}

/// Vente au comptoir du MAGASIN. Le PRIX n'est jamais envoyé par le client : le
/// serveur applique le tarif du client (ou le tarif par défaut) et le fige sur
/// la ligne (règle 13). Paiement : ESPÈCES uniquement (décision 2026-09-15),
/// le reste éventuel part en crédit client dans son plafond.
export class CreateSaleDto {
  @ClientMutationId()
  clientMutationId!: string;

  @ApiPropertyOptional({
    description:
      'UUID généré par le client : un renvoi ne crée pas une seconde vente.',
  })
  @IsCanonicalUuid()
  @IsOptional()
  id?: string;

  @ApiPropertyOptional({
    description: 'Client — absent pour une vente comptoir.',
  })
  @IsCanonicalUuid()
  @IsOptional()
  customerId?: string;

  @ApiProperty({ type: [CreateSaleLineDto] })
  @IsArray()
  @ArrayNotEmpty()
  @ArrayMaxSize(200)
  @ValidateNested({ each: true })
  @Type(() => CreateSaleLineDto)
  lines!: CreateSaleLineDto[];

  @ApiProperty({
    example: 250000,
    description:
      'Espèces ENCAISSÉES pour cette vente, en centimes (≤ total TTC ; la monnaie ' +
      'rendue ne compte pas). Le reste est du crédit client.',
  })
  @IsInt()
  @Min(0)
  @Max(MAX_MONEY)
  paidAmount!: number;

  @ApiPropertyOptional({
    description:
      'Total TTC annoncé au client par l’app (centimes). S’il diffère du total serveur ' +
      '(catalogue local en retard sur un prix), la vente est refusée en 409 : rien ne ' +
      'part en crédit ni ne se rend en monnaie sur un montant faux.',
  })
  @IsInt()
  @Min(0)
  @Max(MAX_MONEY)
  @IsOptional()
  expectedTotalTtc?: number;

  @ApiPropertyOptional()
  @IsString()
  @MaxLength(500)
  @IsOptional()
  note?: string;
}

export class SaleLineDto {
  @ApiProperty() id!: string;
  @ApiProperty() productId!: string;
  @ApiProperty({ example: '12.500' }) quantity!: string;
  @ApiProperty({
    example: 14500,
    description: 'Prix HT figé au moment de la vente.',
  })
  unitPriceHt!: number;
  @ApiProperty({ nullable: true }) priceTierId!: string | null;
  @ApiProperty({ example: '19.00' }) taxRate!: string;
  @ApiProperty() discountAmount!: number;
  @ApiProperty() lineTotalHt!: number;
  @ApiProperty() lineTaxAmount!: number;
  @ApiProperty() lineTotalTtc!: number;
}

export class SaleDto {
  @ApiProperty() id!: string;
  @ApiProperty({ description: 'Numéro de ticket TK-AAAA-NNNNNN' })
  number!: string;
  @ApiProperty({
    nullable: true,
    description: 'Numéro légal FA-AAAA-NNNNNN — serveur, en ligne uniquement.',
  })
  invoiceNumber!: string | null;
  @ApiProperty({
    nullable: true,
    description: 'Date de facturation (date imprimée sur la facture).',
  })
  invoicedAt!: Date | null;
  @ApiProperty({ enum: SaleTypeDto }) type!: SaleTypeDto;
  @ApiProperty({ example: 'VALIDEE' }) status!: string;
  @ApiProperty({ nullable: true }) customerId!: string | null;
  @ApiProperty() userId!: string;
  @ApiProperty({ nullable: true }) cashSessionId!: string | null;
  @ApiProperty() totalHt!: number;
  @ApiProperty() totalTax!: number;
  @ApiProperty() totalTtc!: number;
  @ApiProperty() paidAmount!: number;
  @ApiProperty({
    description:
      'totalTtc − encaissé − paiements ultérieurs. TOUJOURS recalculé.',
  })
  remainingAmount!: number;
  @ApiProperty({ type: [SaleLineDto] }) lines!: SaleLineDto[];
  @ApiProperty() soldAt!: Date;
  @ApiProperty({ nullable: true }) cancelledAt!: Date | null;
}

export class SaleListQueryDto extends PaginationQueryDto {
  @ApiPropertyOptional() @IsCanonicalUuid() @IsOptional() customerId?: string;
}

export class SaleListDto {
  @ApiProperty({ type: [SaleDto] }) data!: SaleDto[];
  @ApiProperty({ type: PaginationMetaDto }) meta!: PaginationMetaDto;
}

export class OpenCashSessionDto {
  @ClientMutationId()
  clientMutationId!: string;

  @ApiProperty({ description: 'Le MAGASIN' })
  @IsCanonicalUuid()
  locationId!: string;
  @ApiProperty({ example: 500000, description: 'Fond de caisse en centimes.' })
  @IsInt()
  @Min(0)
  @Max(MAX_MONEY)
  openingFloat!: number;
}

export class CloseCashSessionDto {
  @ClientMutationId()
  clientMutationId!: string;

  @ApiProperty({
    example: 1250000,
    description: 'Espèces réellement comptées, en centimes.',
  })
  @IsInt()
  @Min(0)
  @Max(MAX_MONEY)
  countedAmount!: number;
  @ApiPropertyOptional()
  @IsString()
  @MaxLength(500)
  @IsOptional()
  note?: string;
}

export class CashSessionDto {
  @ApiProperty() id!: string;
  @ApiProperty() userId!: string;
  @ApiProperty() locationId!: string;
  @ApiProperty({ example: 'OUVERTE' }) status!: string;
  @ApiProperty() openingFloat!: number;
  @ApiProperty({
    description: 'Total des ventes encaissées en espèces (centimes).',
  })
  cashSalesAmount!: number;
  @ApiProperty() cashSalesCount!: number;
  @ApiProperty({
    description: 'Espèces censées être dans le tiroir, en ce moment.',
  })
  currentAmount!: number;
  @ApiProperty({
    description: 'Ventes espèces + entrées (règlements clients), centimes.',
  })
  cashInAmount!: number;
  @ApiProperty({ description: 'Sorties (annulations remboursées), centimes.' })
  cashOutAmount!: number;
  @ApiProperty({ nullable: true, description: 'Attendu calculé à la clôture.' })
  expectedAmount!: number | null;
  @ApiProperty({ nullable: true }) countedAmount!: number | null;
  @ApiProperty({
    nullable: true,
    description: 'countedAmount − expectedAmount (écart).',
  })
  difference!: number | null;
  @ApiProperty() openedAt!: Date;
  @ApiProperty({ nullable: true }) closedAt!: Date | null;
}
