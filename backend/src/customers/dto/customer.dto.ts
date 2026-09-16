import { ClientMutationId } from '../../common/idempotency';
import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import { Transform } from 'class-transformer';
import {
  IsBoolean,
  IsEmail,
  IsInt,
  IsOptional,
  IsString,
  Max,
  MaxLength,
  Min,
  MinLength,
} from 'class-validator';
import {
  PaginationMetaDto,
  PaginationQueryDto,
} from '../../common/dto/pagination.dto';
import {
  IsCanonicalUuid,
  IsOptionalNotNull,
  booleanQuery,
} from '../../common/validation';
import { MAX_MONEY } from '../../sales/dto/sale.dto';

const trim = ({ value }: { value: unknown }) =>
  typeof value === 'string' ? value.trim() : value;
const trimOrNull = ({ value }: { value: unknown }) =>
  typeof value === 'string' ? value.trim() || null : value;

export class CreateCustomerDto {
  @ApiPropertyOptional({ description: 'UUID généré par le client.' })
  @IsCanonicalUuid()
  @IsOptional()
  id?: string;

  @ApiProperty({ example: 'Électricité Benali' })
  @Transform(trim)
  @IsString()
  @MinLength(2)
  @MaxLength(120)
  name!: string;

  @ApiPropertyOptional({ example: '0555 12 34 56' })
  @Transform(trimOrNull)
  @IsString()
  @MaxLength(30)
  @IsOptional()
  phone?: string | null;

  @ApiPropertyOptional()
  @Transform(trimOrNull)
  @IsEmail({}, { message: 'Email invalide' })
  @MaxLength(254)
  @IsOptional()
  email?: string | null;

  @ApiPropertyOptional()
  @Transform(trimOrNull)
  @IsString()
  @MaxLength(300)
  @IsOptional()
  address?: string | null;

  @ApiPropertyOptional()
  @Transform(trimOrNull)
  @IsString()
  @MaxLength(1000)
  @IsOptional()
  notes?: string | null;

  @ApiPropertyOptional({
    description: 'Tarif de ses ventes — ADMIN seul (`price.manage`).',
  })
  @IsCanonicalUuid()
  @IsOptional()
  priceTierId?: string | null;

  @ApiPropertyOptional({
    default: 0,
    description:
      'Plafond de crédit en centimes — ADMIN seul. 0 = aucune vente à crédit.',
  })
  @IsInt()
  @Min(0)
  @Max(MAX_MONEY)
  @IsOptional()
  creditLimit?: number;
}

export class UpdateCustomerDto {
  @ApiPropertyOptional()
  @Transform(trim)
  @IsOptionalNotNull()
  @IsString()
  @MinLength(2)
  @MaxLength(120)
  name?: string;

  @ApiPropertyOptional({ nullable: true })
  @Transform(trimOrNull)
  @IsString()
  @MaxLength(30)
  @IsOptional()
  phone?: string | null;

  @ApiPropertyOptional({ nullable: true })
  @Transform(trimOrNull)
  @IsEmail({}, { message: 'Email invalide' })
  @MaxLength(254)
  @IsOptional()
  email?: string | null;

  @ApiPropertyOptional({ nullable: true })
  @Transform(trimOrNull)
  @IsString()
  @MaxLength(300)
  @IsOptional()
  address?: string | null;

  @ApiPropertyOptional({ nullable: true })
  @Transform(trimOrNull)
  @IsString()
  @MaxLength(1000)
  @IsOptional()
  notes?: string | null;

  @ApiPropertyOptional() @IsOptionalNotNull() @IsBoolean() isActive?: boolean;

  @ApiPropertyOptional({ nullable: true, description: 'ADMIN seul' })
  @IsCanonicalUuid()
  @IsOptional()
  priceTierId?: string | null;

  @ApiPropertyOptional({ description: 'ADMIN seul' })
  @IsOptionalNotNull()
  @IsInt()
  @Min(0)
  @Max(MAX_MONEY)
  creditLimit?: number;
}

export class CustomerListQueryDto extends PaginationQueryDto {
  @ApiPropertyOptional({ default: false })
  @Transform(booleanQuery)
  @IsBoolean()
  @IsOptional()
  includeInactive = false;
}

export class CustomerDto {
  @ApiProperty() id!: string;
  @ApiProperty({ nullable: true }) code!: string | null;
  @ApiProperty() name!: string;
  @ApiProperty({ nullable: true }) phone!: string | null;
  @ApiProperty({ nullable: true }) email!: string | null;
  @ApiProperty({ nullable: true }) address!: string | null;
  @ApiProperty({ nullable: true }) notes!: string | null;
  @ApiProperty({ nullable: true }) priceTierId!: string | null;
  @ApiProperty() creditLimit!: number;
  @ApiProperty({
    description: 'Dette restante en centimes, TOUJOURS recalculée.',
  })
  balanceDue!: number;
  @ApiProperty() isActive!: boolean;
}

export class CustomerListDto {
  @ApiProperty({ type: [CustomerDto] }) data!: CustomerDto[];
  @ApiProperty({ type: PaginationMetaDto }) meta!: PaginationMetaDto;
}

/// Règlement d'une dette — ESPÈCES uniquement (décision 2026-09-15).
export class CreateCustomerPaymentDto {
  @ClientMutationId()
  clientMutationId!: string;

  @ApiPropertyOptional({ description: 'UUID généré par le client.' })
  @IsCanonicalUuid()
  @IsOptional()
  id?: string;

  @ApiProperty() @IsCanonicalUuid() customerId!: string;

  @ApiPropertyOptional({
    description: 'Vente réglée (sinon : acompte sur la dette globale).',
  })
  @IsCanonicalUuid()
  @IsOptional()
  saleId?: string;

  @ApiProperty({ example: 20000, description: 'Montant en centimes.' })
  @IsInt()
  @Min(1)
  @Max(MAX_MONEY)
  amount!: number;

  @ApiPropertyOptional()
  @IsString()
  @MaxLength(500)
  @IsOptional()
  note?: string;
}

export class CustomerPaymentDto {
  @ApiProperty() id!: string;
  @ApiProperty() customerId!: string;
  @ApiProperty({ nullable: true }) saleId!: string | null;
  @ApiProperty() amount!: number;
  @ApiProperty() paidAt!: Date;
  @ApiProperty({ description: 'Dette restante après ce règlement.' })
  balanceDue!: number;
}
