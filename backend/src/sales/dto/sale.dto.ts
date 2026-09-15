import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import { Type } from 'class-transformer';
import {
  ArrayNotEmpty,
  IsArray,
  IsEnum,
  IsInt,
  IsNumberString,
  IsOptional,
  IsString,
  IsUUID,
  Max,
  MaxLength,
  Min,
  ValidateNested,
} from 'class-validator';
import { IsCanonicalUuid } from '../../common/validation';

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
  @ApiProperty() @IsUUID() productId!: string;

  @ApiProperty({
    example: '12.500',
    description: 'Quantité décimale, en chaîne.',
  })
  @IsNumberString()
  quantity!: string;

  @ApiPropertyOptional({
    description:
      'Remise en centimes. Réservée à l’ADMIN (permission `sale.discount`) — ' +
      'le vendeur n’applique aucune remise libre.',
  })
  @IsInt()
  @Min(0)
  @IsOptional()
  discountAmount?: number;
}

export class CreateSaleDto {
  @ApiPropertyOptional({
    description:
      'UUID généré par le client (vente hors-ligne). Absent → généré serveur.',
  })
  @IsUUID()
  @IsOptional()
  id?: string;

  @ApiPropertyOptional({
    description: 'Client — absent pour une vente comptoir.',
  })
  @IsUUID()
  @IsOptional()
  customerId?: string;

  @ApiProperty({ enum: SaleTypeDto, default: SaleTypeDto.TICKET })
  @IsEnum(SaleTypeDto)
  type!: SaleTypeDto;

  @ApiProperty() @IsUUID() locationId!: string;

  @ApiPropertyOptional({
    description: 'Session de caisse — OBLIGATOIRE si paiement espèces.',
  })
  @IsUUID()
  @IsOptional()
  cashSessionId?: string;

  @ApiProperty({ type: [CreateSaleLineDto] })
  @IsArray()
  @ArrayNotEmpty()
  @ValidateNested({ each: true })
  @Type(() => CreateSaleLineDto)
  lines!: CreateSaleLineDto[];

  @ApiProperty({
    example: 250000,
    description: 'Montant encaissé, en centimes.',
  })
  @IsInt()
  @Min(0)
  paidAmount!: number;

  @ApiPropertyOptional({ enum: PaymentMethodDto })
  @IsEnum(PaymentMethodDto)
  @IsOptional()
  paymentMethod?: PaymentMethodDto;

  @ApiPropertyOptional({
    description: 'Échéance si vente à crédit (ISO 8601).',
  })
  @IsString()
  @IsOptional()
  dueDate?: string;

  @ApiPropertyOptional({
    description: 'Idempotence sync — unique par mutation.',
  })
  @IsUUID()
  @IsOptional()
  clientMutationId?: string;
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
  @ApiProperty({ example: '19.00' }) taxRate!: string;
  @ApiProperty() discountAmount!: number;
  @ApiProperty() lineTotalHt!: number;
  @ApiProperty() lineTaxAmount!: number;
  @ApiProperty() lineTotalTtc!: number;
}

export class SaleDto {
  @ApiProperty() id!: string;
  @ApiProperty({ description: 'Numéro de ticket' }) number!: string;
  @ApiProperty({
    nullable: true,
    description: 'Numéro légal FAC-AAAA-NNNNN — serveur, en ligne uniquement.',
  })
  invoiceNumber!: string | null;
  @ApiProperty({ enum: SaleTypeDto }) type!: SaleTypeDto;
  @ApiProperty({ example: 'VALIDEE' }) status!: string;
  @ApiProperty({ nullable: true }) customerId!: string | null;
  @ApiProperty() totalHt!: number;
  @ApiProperty() totalTax!: number;
  @ApiProperty() totalTtc!: number;
  @ApiProperty() paidAmount!: number;
  @ApiProperty({
    description:
      'totalTtc − paidAmount − paiements ultérieurs. TOUJOURS recalculé.',
  })
  remainingAmount!: number;
  @ApiProperty({ type: [SaleLineDto] }) lines!: SaleLineDto[];
  @ApiProperty() soldAt!: Date;
}

export class CreateCustomerPaymentDto {
  @ApiProperty() @IsUUID() customerId!: string;
  @ApiPropertyOptional() @IsUUID() @IsOptional() saleId?: string;
  @ApiProperty({ example: 20000, description: 'Montant en centimes.' })
  @IsInt()
  @Min(1)
  amount!: number;
  @ApiProperty({ enum: PaymentMethodDto })
  @IsEnum(PaymentMethodDto)
  method!: PaymentMethodDto;
  @ApiPropertyOptional() @IsString() @IsOptional() note?: string;
  @ApiPropertyOptional() @IsUUID() @IsOptional() clientMutationId?: string;
}

/// Borne des montants en centimes : colonnes `Int` PostgreSQL (≈ 21 M DA).
export const MAX_MONEY = 2_000_000_000;

export class OpenCashSessionDto {
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
