import { ClientMutationId } from '../../common/idempotency';
import {
  ApiProperty,
  ApiPropertyOptional,
  IntersectionType,
} from '@nestjs/swagger';
import { ExportFormatQueryDto } from '../../common/export/export';
import {
  IsBoolean,
  IsEmail,
  IsIn,
  IsInt,
  IsOptional,
  IsString,
  MaxLength,
  Max,
  Min,
  MinLength,
} from 'class-validator';
import { Transform } from 'class-transformer';
import {
  PaginationMetaDto,
  PaginationQueryDto,
} from '../../common/dto/pagination.dto';
import { MAX_MONEY } from '../../sales/dto/sale.dto';
import {
  booleanQuery,
  ClientGeneratedId,
  IsCanonicalUuid,
  IsOptionalNotNull,
} from '../../common/validation';

const trim = ({ value }: { value: unknown }) =>
  typeof value === 'string' ? value.trim() : value;
const trimOrNull = ({ value }: { value: unknown }) =>
  typeof value === 'string' ? value.trim() || null : value;

export class CreateSupplierDto {
  @ApiPropertyOptional() @ClientGeneratedId() id?: string;
  @ApiProperty()
  @Transform(trim)
  @IsString()
  @MinLength(2)
  @MaxLength(150)
  name!: string;
  @ApiPropertyOptional()
  @Transform(trimOrNull)
  @IsString()
  @MaxLength(30)
  @IsOptional()
  phone?: string;
  @ApiPropertyOptional()
  @Transform(trimOrNull)
  @IsEmail()
  @MaxLength(150)
  @IsOptional()
  email?: string;
  @ApiPropertyOptional()
  @Transform(trimOrNull)
  @IsString()
  @MaxLength(250)
  @IsOptional()
  address?: string;
  @ApiPropertyOptional()
  @Transform(trimOrNull)
  @IsString()
  @MaxLength(150)
  @IsOptional()
  contactName?: string;
  @ApiPropertyOptional()
  @Transform(trimOrNull)
  @IsString()
  @MaxLength(500)
  @IsOptional()
  notes?: string;
  @ApiPropertyOptional({
    description:
      'Dette déjà due à la mise en service, en centimes (admin uniquement).',
  })
  @IsInt()
  @Min(0)
  @Max(MAX_MONEY)
  @IsOptional()
  openingBalance?: number;
}

export class UpdateSupplierDto {
  @ApiPropertyOptional()
  @IsString()
  @MinLength(2)
  @MaxLength(150)
  @IsOptionalNotNull()
  name?: string;
  @ApiPropertyOptional({ nullable: true })
  @Transform(trimOrNull)
  @IsString()
  @MaxLength(30)
  @IsOptional()
  phone?: string | null;
  @ApiPropertyOptional({ nullable: true })
  @Transform(trimOrNull)
  @IsEmail()
  @MaxLength(150)
  @IsOptional()
  email?: string | null;
  @ApiPropertyOptional({ nullable: true })
  @Transform(trimOrNull)
  @IsString()
  @MaxLength(250)
  @IsOptional()
  address?: string | null;
  @ApiPropertyOptional({ nullable: true })
  @Transform(trimOrNull)
  @IsString()
  @MaxLength(150)
  @IsOptional()
  contactName?: string | null;
  @ApiPropertyOptional({ nullable: true })
  @Transform(trimOrNull)
  @IsString()
  @MaxLength(500)
  @IsOptional()
  notes?: string | null;
  @ApiPropertyOptional()
  @IsInt()
  @Min(0)
  @Max(MAX_MONEY)
  @IsOptionalNotNull()
  openingBalance?: number;
  @ApiPropertyOptional()
  @IsBoolean()
  @IsOptionalNotNull()
  isActive?: boolean;
}

export class SupplierDto {
  @ApiProperty() id!: string;
  @ApiProperty({ nullable: true }) code!: string | null;
  @ApiProperty() name!: string;
  @ApiProperty({ nullable: true }) phone!: string | null;
  @ApiProperty({ nullable: true }) email!: string | null;
  @ApiProperty({ nullable: true }) address!: string | null;
  @ApiProperty({ nullable: true }) contactName!: string | null;
  @ApiProperty({ nullable: true }) notes!: string | null;
  @ApiProperty({
    description: 'Dette reprise à la mise en service (centimes).',
  })
  openingBalance!: number;
  @ApiProperty({
    description:
      'Reste dû, TOUJOURS recalculé : reprise + marchandise reçue − paiements.',
  })
  balanceDue!: number;
  @ApiProperty({ description: 'Total déjà payé à ce fournisseur (centimes).' })
  paidAmount!: number;
  @ApiProperty({
    description:
      'Total TTC de la marchandise RÉELLEMENT reçue, net des retours (centimes).',
  })
  receivedAmount!: number;
  @ApiProperty() isActive!: boolean;
}

/// Prix d'achat d'un produit chez ce fournisseur, d'une réception à l'autre.
export class SupplierProductPriceDto {
  @ApiProperty() productId!: string;
  @ApiProperty() name!: string;
  @ApiProperty() sku!: string;
  @ApiProperty({ description: 'Réceptions (bons) de ce produit chez lui.' })
  receptions!: number;
  @ApiProperty({ description: 'Premier prix HT réceptionné (centimes).' })
  firstPriceHt!: number;
  @ApiProperty({
    nullable: true,
    description: 'Prix HT de la réception précédente (centimes).',
  })
  previousPriceHt!: number | null;
  @ApiProperty({ description: 'Dernier prix HT réceptionné (centimes).' })
  lastPriceHt!: number;
  @ApiProperty() lastReceivedAt!: Date;
}

/// Indicateurs d'un fournisseur (P1 bis n°21m). Le total acheté est
/// `SupplierDto.receivedAmount` (reçu net des retours).
export class SupplierStatsDto {
  @ApiProperty({ description: 'Produits distincts réceptionnés chez lui.' })
  productCount!: number;
  @ApiProperty({
    description:
      'Réceptions de commandes portant une date de livraison prévue.',
  })
  deliveriesWithDate!: number;
  @ApiProperty({ description: '… dont reçues au plus tard à la date prévue.' })
  deliveriesOnTime!: number;
  @ApiProperty({
    type: [SupplierProductPriceDto],
    description:
      'Produits, du plus récemment reçu au plus ancien (100 au plus).',
  })
  prices!: SupplierProductPriceDto[];
}

export class SupplierListQueryDto extends PaginationQueryDto {
  @ApiPropertyOptional({ default: false })
  @Transform(booleanQuery)
  @IsBoolean()
  @IsOptional()
  includeInactive = false;
}

/// Export de la liste (et des dettes fournisseurs avec `debtOnly`).
export class SupplierExportQueryDto extends IntersectionType(
  SupplierListQueryDto,
  ExportFormatQueryDto,
) {
  @ApiPropertyOptional({
    default: false,
    description: 'Seulement ceux qui ont une dette (export « dettes »).',
  })
  @Transform(booleanQuery)
  @IsBoolean()
  @IsOptional()
  debtOnly = false;
}

export class SupplierListDto {
  @ApiProperty({ type: [SupplierDto] }) data!: SupplierDto[];
  @ApiProperty({ type: PaginationMetaDto }) meta!: PaginationMetaDto;
}

export class CreateSupplierPaymentDto {
  @ClientMutationId()
  clientMutationId!: string;

  @ApiPropertyOptional({ description: 'Id client (renvoi idempotent).' })
  @ClientGeneratedId()
  id?: string;

  @ApiProperty() @IsCanonicalUuid() supplierId!: string;

  @ApiProperty({ example: 300000, description: 'Montant en centimes.' })
  @IsInt()
  @Min(1)
  @Max(MAX_MONEY)
  amount!: number;

  @ApiProperty({
    description:
      'true : sortie de la caisse OUVERTE (rapport Z) ; false : payé hors caisse ' +
      '(virement, espèces hors tiroir).',
  })
  @IsBoolean()
  fromCash!: boolean;

  @ApiPropertyOptional({
    enum: ['ESPECES', 'CHEQUE', 'VIREMENT', 'CARTE', 'AUTRE'],
    description:
      'Hors caisse seulement ; un paiement de caisse est en espèces.',
  })
  @IsIn(['ESPECES', 'CHEQUE', 'VIREMENT', 'CARTE', 'AUTRE'])
  @IsOptional()
  method?: 'ESPECES' | 'CHEQUE' | 'VIREMENT' | 'CARTE' | 'AUTRE';

  @ApiPropertyOptional()
  @IsString()
  @MaxLength(500)
  @IsOptional()
  note?: string;
}

export class SupplierPaymentDto {
  @ApiProperty() id!: string;
  @ApiProperty() supplierId!: string;
  @ApiProperty() amount!: number;
  @ApiProperty() method!: string;
  @ApiProperty({ description: 'Sortie de caisse enregistrée.' })
  fromCash!: boolean;
  @ApiProperty() paidAt!: Date;
  @ApiProperty({
    nullable: true,
    description: 'Renseigné sur une contre-passation (montant négatif).',
  })
  reversesPaymentId!: string | null;
  @ApiProperty({ description: 'Reste dû après ce paiement.' })
  balanceDue!: number;
}
