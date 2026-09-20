import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import { Transform, Type } from 'class-transformer';
import {
  ArrayMaxSize,
  ArrayNotEmpty,
  IsArray,
  IsInt,
  IsOptional,
  IsString,
  Matches,
  Max,
  MaxLength,
  Min,
  ValidateNested,
} from 'class-validator';
import {
  PaginationMetaDto,
  PaginationQueryDto,
} from '../../common/dto/pagination.dto';
import { ClientMutationId } from '../../common/idempotency';
import { IsCanonicalUuid } from '../../common/validation';
import { MAX_MONEY } from '../../sales/dto/sale.dto';

export class ReceptionLineInputDto {
  @ApiProperty() @IsCanonicalUuid() productId!: string;

  @ApiPropertyOptional({
    description:
      'Ligne de commande couverte. Absente = réception hors commande. ' +
      'La quantité reçue ne peut jamais dépasser le reste à recevoir.',
  })
  @IsCanonicalUuid()
  @IsOptional()
  purchaseLineId?: string;

  @ApiProperty({
    example: '70.000',
    description: 'Quantité RÉELLEMENT reçue (décimale, 3 décimales au plus).',
    pattern: '^\d{1,11}(\.\d{1,3})?$',
  })
  @IsString()
  @MaxLength(20)
  @Matches(/^\d{1,11}(\.\d{1,3})?$/, {
    message: 'receivedQuantity : décimale à 3 décimales au plus attendue',
  })
  receivedQuantity!: string;

  @ApiProperty({
    example: 120000,
    description:
      'Prix d’achat HT en centimes. IGNORÉ quand la ligne est rattachée à une ' +
      'commande : c’est le prix confirmé par l’administrateur qui fait foi.',
  })
  @IsInt()
  @Min(0)
  @Max(MAX_MONEY)
  unitPriceHt!: number;
}

export class CreateReceptionDto {
  @ApiPropertyOptional({ description: 'UUID généré par le client.' })
  @IsCanonicalUuid()
  @IsOptional()
  id?: string;

  @ApiPropertyOptional({ description: 'Absent = réception hors commande.' })
  @IsCanonicalUuid()
  @IsOptional()
  purchaseOrderId?: string;

  @ApiProperty() @IsCanonicalUuid() supplierId!: string;

  @ApiProperty({ description: 'Emplacement où la marchandise entre.' })
  @IsCanonicalUuid()
  locationId!: string;

  @ApiProperty({ type: [ReceptionLineInputDto] })
  @IsArray()
  @ArrayNotEmpty()
  @ArrayMaxSize(200)
  @ValidateNested({ each: true })
  @Type(() => ReceptionLineInputDto)
  lines!: ReceptionLineInputDto[];

  @ApiPropertyOptional()
  @Transform(({ value }: { value: unknown }) =>
    typeof value === 'string' ? value.trim() || null : value,
  )
  @IsString()
  @MaxLength(500)
  @IsOptional()
  note?: string | null;

  /// La réception augmente le stock ET la dette fournisseur : clé obligatoire.
  @ClientMutationId() clientMutationId!: string;
}

export class ReceptionLineDto {
  @ApiProperty() id!: string;
  @ApiProperty() productId!: string;
  @ApiProperty({ nullable: true }) purchaseLineId!: string | null;
  @ApiProperty({ example: '70.000' }) receivedQuantity!: string;
  @ApiProperty() unitPriceHt!: number;
  @ApiProperty() lineTotalHt!: number;
  @ApiProperty() lineTotalTtc!: number;
}

export class ReceptionDto {
  @ApiProperty() id!: string;
  @ApiProperty() number!: string;
  @ApiProperty({ nullable: true }) purchaseOrderId!: string | null;
  @ApiProperty() supplierId!: string;
  @ApiProperty() locationId!: string;
  @ApiProperty() userId!: string;
  @ApiProperty() receivedAt!: Date;
  @ApiProperty({ nullable: true }) note!: string | null;
  @ApiProperty({ description: 'Montant TTC ajouté à la dette fournisseur.' })
  totalTtc!: number;
  @ApiProperty({ type: [ReceptionLineDto] }) lines!: ReceptionLineDto[];
}

export class ReceptionListQueryDto extends PaginationQueryDto {
  @ApiPropertyOptional() @IsCanonicalUuid() @IsOptional() supplierId?: string;
  @ApiPropertyOptional()
  @IsCanonicalUuid()
  @IsOptional()
  purchaseOrderId?: string;
}

export class ReceptionListDto {
  @ApiProperty({ type: [ReceptionDto] }) data!: ReceptionDto[];
  @ApiProperty({ type: PaginationMetaDto }) meta!: PaginationMetaDto;
}
