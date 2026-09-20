import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import { Transform, Type } from 'class-transformer';
import {
  ArrayMaxSize,
  ArrayNotEmpty,
  IsArray,
  IsIn,
  IsInt,
  IsISO8601,
  IsOptional,
  IsString,
  MaxLength,
  MinLength,
  Max,
  Min,
  ValidateNested,
} from 'class-validator';
import {
  PaginationMetaDto,
  PaginationQueryDto,
} from '../../common/dto/pagination.dto';
import { MAX_MONEY } from '../../sales/dto/sale.dto';
import { IsCanonicalUuid, IsOptionalNotNull } from '../../common/validation';

export const PURCHASE_STATUSES = [
  'BROUILLON',
  'COMMANDEE',
  'CONFIRMEE',
  'PARTIELLEMENT_RECUE',
  'RECUE',
  'CLOTUREE',
  'ANNULEE',
] as const;

export class PurchaseLineInputDto {
  @ApiProperty() @IsCanonicalUuid() productId!: string;

  @ApiProperty({ example: '100.000' })
  @IsString()
  @MaxLength(20)
  orderedQuantity!: string;

  @ApiProperty({ example: 120000, description: 'Prix d’achat HT en centimes.' })
  @IsInt()
  @Min(0)
  @Max(MAX_MONEY)
  unitPriceHt!: number;
}

export class CreatePurchaseOrderDto {
  @ApiPropertyOptional({ description: 'UUID généré par le client.' })
  @IsCanonicalUuid()
  @IsOptional()
  id?: string;

  @ApiProperty() @IsCanonicalUuid() supplierId!: string;

  @ApiPropertyOptional({ description: 'Livraison attendue (ISO 8601).' })
  @IsISO8601()
  @IsOptional()
  expectedDate?: string;

  @ApiPropertyOptional({ description: 'Échéance de paiement (ISO 8601).' })
  @IsISO8601()
  @IsOptional()
  dueDate?: string;

  @ApiProperty({ type: [PurchaseLineInputDto] })
  @IsArray()
  @ArrayNotEmpty()
  @ArrayMaxSize(200)
  @ValidateNested({ each: true })
  @Type(() => PurchaseLineInputDto)
  lines!: PurchaseLineInputDto[];

  @ApiPropertyOptional()
  @Transform(({ value }: { value: unknown }) =>
    typeof value === 'string' ? value.trim() || null : value,
  )
  @IsString()
  @MaxLength(500)
  @IsOptional()
  note?: string;
}

/// Modification d'une commande PAS ENCORE confirmée : les lignes envoyées
/// REMPLACENT les précédentes (une commande n'a pas d'historique de brouillon).
export class UpdatePurchaseOrderDto {
  @ApiPropertyOptional({ description: 'Livraison attendue (ISO 8601).' })
  @IsISO8601()
  @IsOptional()
  expectedDate?: string | null;

  @ApiPropertyOptional({ description: 'Échéance de paiement (ISO 8601).' })
  @IsISO8601()
  @IsOptional()
  dueDate?: string | null;

  @ApiPropertyOptional({
    description:
      'COMMANDEE : commande envoyée au fournisseur (depuis BROUILLON seulement, jamais retour).',
    enum: ['COMMANDEE'],
  })
  @IsIn(['COMMANDEE'])
  @IsOptionalNotNull()
  status?: 'COMMANDEE';

  @ApiPropertyOptional({ type: [PurchaseLineInputDto] })
  @IsArray()
  @ArrayNotEmpty()
  @ArrayMaxSize(200)
  @ValidateNested({ each: true })
  @Type(() => PurchaseLineInputDto)
  @IsOptionalNotNull()
  lines?: PurchaseLineInputDto[];

  @ApiPropertyOptional()
  @Transform(({ value }: { value: unknown }) =>
    typeof value === 'string' ? value.trim() || null : value,
  )
  @IsString()
  @MaxLength(500)
  @IsOptional()
  note?: string | null;
}

export class ConfirmPurchaseOrderDto {
  @ApiProperty({
    description:
      '`updatedAt` de la commande AFFICHÉE à l’admin. Si elle a été modifiée ' +
      'depuis, 409 : on ne confirme jamais une version que l’on n’a pas vue.',
  })
  @IsISO8601({ strict: true })
  expectedUpdatedAt!: string;
}

export class ClosePurchaseOrderDto {
  @ApiProperty({
    description:
      'Pourquoi le reliquat est abandonné (rupture chez le fournisseur, ' +
      'commande soldée à l’amiable…). Tracé au journal d’audit.',
    minLength: 3,
    maxLength: 500,
  })
  @Transform(({ value }: { value: unknown }) =>
    typeof value === 'string' ? value.trim() : value,
  )
  @IsString()
  @MinLength(3)
  @MaxLength(500)
  reason!: string;
}

export class PurchaseLineDto {
  @ApiProperty() id!: string;
  @ApiProperty() productId!: string;
  @ApiProperty({ example: '100.000' }) orderedQuantity!: string;
  @ApiProperty({
    example: '70.000',
    description: 'Cumul des réceptions — projection, jamais écrite à la main.',
  })
  receivedQuantity!: string;
  @ApiProperty({ example: '30.000' }) remainingQuantity!: string;
  @ApiProperty() unitPriceHt!: number;
  @ApiProperty({ example: '19.00' }) taxRate!: string;
  @ApiProperty() lineTotalHt!: number;
  @ApiProperty() lineTotalTtc!: number;
}

export class PurchaseOrderDto {
  @ApiProperty() id!: string;
  @ApiProperty({ description: 'Numéro BC-AAAA-NNNNN attribué serveur.' })
  number!: string;
  @ApiProperty() supplierId!: string;
  @ApiProperty({
    example: 'BROUILLON',
    description:
      'BROUILLON → COMMANDEE → CONFIRMEE → PARTIELLEMENT_RECUE → RECUE (+ ANNULEE)',
  })
  status!: string;
  @ApiProperty() createdById!: string;
  @ApiProperty({ nullable: true }) confirmedById!: string | null;
  @ApiProperty() orderDate!: Date;
  @ApiProperty({ nullable: true }) expectedDate!: Date | null;
  @ApiProperty({ nullable: true }) dueDate!: Date | null;
  @ApiProperty({ nullable: true }) confirmedAt!: Date | null;
  @ApiProperty({ nullable: true }) cancelledAt!: Date | null;
  @ApiProperty({ nullable: true }) closedAt!: Date | null;
  @ApiProperty({ nullable: true }) closedReason!: string | null;
  @ApiProperty() totalHt!: number;
  @ApiProperty() totalTax!: number;
  @ApiProperty() totalTtc!: number;
  @ApiProperty({ nullable: true }) note!: string | null;
  @ApiProperty({ description: 'Version : à renvoyer pour confirmer.' })
  updatedAt!: Date;
  @ApiProperty({ type: [PurchaseLineDto] }) lines!: PurchaseLineDto[];
}

export class PurchaseOrderListQueryDto extends PaginationQueryDto {
  @ApiPropertyOptional() @IsCanonicalUuid() @IsOptional() supplierId?: string;

  @ApiPropertyOptional({ enum: PURCHASE_STATUSES })
  @IsIn(PURCHASE_STATUSES)
  @IsOptional()
  status?: (typeof PURCHASE_STATUSES)[number];
}

export class PurchaseOrderListDto {
  @ApiProperty({ type: [PurchaseOrderDto] }) data!: PurchaseOrderDto[];
  @ApiProperty({ type: PaginationMetaDto }) meta!: PaginationMetaDto;
}
