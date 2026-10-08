import { ApiProperty, ApiPropertyOptional, PickType } from '@nestjs/swagger';
import { Transform, Type } from 'class-transformer';
import {
  ArrayMaxSize,
  ArrayNotEmpty,
  IsArray,
  IsOptional,
  IsString,
  MaxLength,
  ValidateNested,
} from 'class-validator';
import { CreateCustomerDto } from '../customers/dto/customer.dto';
import { ClientMutationId } from '../common/idempotency';
import { IsCanonicalUuid } from '../common/validation';
import { ReceptionLineInputDto } from '../receptions/dto/reception.dto';
import { CreateSaleLineDto } from '../sales/dto/sale.dto';

export class CreateConfrereDto extends PickType(CreateCustomerDto, [
  'id',
  'name',
  'phone',
]) {}

/// Achat à un confrère (`receive` seul) ou échange (`receive` + `give`) :
/// une seule transaction, tout ou rien (règle 3). Rien n'est payé ici — le
/// montant va dans les dettes ; la vente simple passe par le panier.
export class CreateConfrereDealDto {
  /// Clé de l'ACHAT (réception), stable pour tous les renvois.
  @ClientMutationId() clientMutationId!: string;

  @ApiProperty({
    type: [ReceptionLineInputDto],
    description:
      'Ce que le confrère me donne (entre au magasin, prix d’achat).',
  })
  @IsArray()
  @ArrayNotEmpty()
  @ArrayMaxSize(200)
  @ValidateNested({ each: true })
  @Type(() => ReceptionLineInputDto)
  receive!: ReceptionLineInputDto[];

  @ApiPropertyOptional({
    type: [CreateSaleLineDto],
    description:
      'Échange : ce que je lui donne (vente à crédit, sans plafond).',
  })
  @IsArray()
  @ArrayMaxSize(200)
  @ValidateNested({ each: true })
  @Type(() => CreateSaleLineDto)
  @IsOptional()
  give?: CreateSaleLineDto[];

  @ApiPropertyOptional({
    format: 'uuid',
    description: 'Clé de la VENTE de l’échange — obligatoire avec `give`.',
  })
  @IsCanonicalUuid()
  @IsOptional()
  saleMutationId?: string;

  @ApiPropertyOptional()
  @Transform(({ value }: { value: unknown }) =>
    typeof value === 'string' ? value.trim() || null : value,
  )
  @IsString()
  @MaxLength(500)
  @IsOptional()
  note?: string | null;
}

export class ConfrereDto {
  @ApiProperty({ description: 'Identifiant CLIENT du confrère.' }) id!: string;
  @ApiProperty() supplierId!: string;
  @ApiProperty() name!: string;
  @ApiProperty({ nullable: true }) phone!: string | null;
  @ApiProperty({ description: 'Ce qu’il me doit (centimes).' })
  theyOwe!: number;
  @ApiProperty({ description: 'Ce que je lui dois (centimes).' })
  weOwe!: number;
  @ApiProperty({ description: 'theyOwe − weOwe : > 0, il me doit.' })
  net!: number;
}

export class ConfrereDealDto {
  @ApiProperty() receptionNumber!: string;
  @ApiProperty({ nullable: true }) saleNumber!: string | null;
  @ApiProperty({ type: ConfrereDto }) confrere!: ConfrereDto;
}
