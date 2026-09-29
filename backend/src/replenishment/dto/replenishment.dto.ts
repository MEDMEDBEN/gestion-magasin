import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import { Transform, Type } from 'class-transformer';
import {
  ArrayMaxSize,
  ArrayNotEmpty,
  IsArray,
  IsBoolean,
  IsInt,
  IsOptional,
  IsString,
  Max,
  MaxLength,
  Min,
  ValidateNested,
} from 'class-validator';
import { PaginationMetaDto } from '../../common/dto/pagination.dto';
import {
  booleanQuery,
  IsCanonicalUuid,
  IsOptionalNotNull,
} from '../../common/validation';

/// Pas d'héritage de `PaginationQueryDto` : il apporterait `sort` et `q`, que
/// cette route ACCEPTERAIT et ignorerait en silence (le tri est figé sur
/// l'urgence, il n'y a pas de recherche). Un paramètre annoncé dans l'OpenAPI et
/// sans effet est un mensonge de contrat. Les bornes, elles, sont les mêmes.
export class ReplenishmentQueryDto {
  @ApiPropertyOptional({ default: 1, minimum: 1, maximum: 1_000_000 })
  @Type(() => Number)
  @IsInt()
  @Min(1)
  @Max(1_000_000)
  @IsOptional()
  page = 1;

  @ApiPropertyOptional({ default: 50, minimum: 1, maximum: 200 })
  @Type(() => Number)
  @IsInt()
  @Min(1)
  @Max(200)
  @IsOptional()
  limit = 50;

  @ApiPropertyOptional({
    description: 'Ne rendre que les ruptures (stock à zéro ou négatif).',
  })
  @Transform(booleanQuery)
  @IsBoolean()
  @IsOptional()
  outOfStockOnly?: boolean;

  @ApiPropertyOptional({
    description: 'Ne rendre que les produits de ce fournisseur principal.',
  })
  @IsOptionalNotNull()
  @IsCanonicalUuid()
  supplierId?: string;
}

export class ReplenishmentLineDto {
  @ApiProperty() productId!: string;
  @ApiProperty() sku!: string;
  @ApiProperty() name!: string;
  @ApiProperty({ description: 'Unité de vente (pièce, mètre…).' })
  unit!: string;

  @ApiProperty({
    description:
      'Stock en MAGASIN + DÉPÔT. Le transit est exclu — ' +
      'une marchandise en route n’est pas sur l’étagère.',
    example: '8.000',
  })
  quantity!: string;

  @ApiProperty({ example: '20.000' }) minThreshold!: string;
  @ApiProperty({ example: '0.000' }) safetyStock!: string;

  @ApiProperty({
    description:
      'Quantité PROPOSÉE, à modifier avant de commander (spec §19). ' +
      'Cible = 2 × seuil + stock de sécurité, plancher d’une unité.',
    example: '32.000',
  })
  suggestedQuantity!: string;

  @ApiProperty({ description: 'Rupture : plus rien en magasin ni au dépôt.' })
  isOutOfStock!: boolean;

  @ApiProperty({ nullable: true }) supplierId!: string | null;
  @ApiProperty({ nullable: true }) supplierName!: string | null;

  @ApiProperty({
    nullable: true,
    description:
      'Dernier prix d’achat HT en centimes, pour estimer la commande. ' +
      '`null` si le produit n’a jamais été réceptionné.',
  })
  lastPurchasePriceHt!: number | null;
}

export class ReplenishmentListDto {
  @ApiProperty({ type: [ReplenishmentLineDto] }) data!: ReplenishmentLineDto[];
  @ApiProperty({ type: PaginationMetaDto }) meta!: PaginationMetaDto;

  @ApiProperty({
    description:
      'Nombre de ruptures sur l’ensemble du résultat, pagination mise à part. ' +
      'Le filtre `supplierId`, lui, le restreint comme le reste.',
  })
  outOfStockCount!: number;
}

/// Une ligne retenue sur la liste « à racheter » : produit et quantité (celle
/// proposée, éventuellement ajustée).
export class PrepareOrderLineDto {
  @ApiProperty() @IsCanonicalUuid() productId!: string;

  @ApiProperty({ example: '12.000' })
  @IsString()
  @MaxLength(20)
  quantity!: string;
}

/// Préparation des commandes (P1 bis → P2 n°22, spec §28).
export class PrepareOrdersDto {
  @ApiProperty({ type: [PrepareOrderLineDto] })
  @IsArray()
  @ArrayNotEmpty()
  @ArrayMaxSize(200)
  @ValidateNested({ each: true })
  @Type(() => PrepareOrderLineDto)
  lines!: PrepareOrderLineDto[];
}

export class PreparedOrderDto {
  @ApiProperty() id!: string;
  @ApiProperty({ example: 'BC-2026-00012' }) number!: string;
  @ApiProperty() supplierId!: string;
  @ApiProperty() supplierName!: string;
  @ApiProperty() lineCount!: number;
}

export class PrepareOrdersResultDto {
  @ApiProperty({
    type: [PreparedOrderDto],
    description: 'Commandes BROUILLON créées, une par fournisseur principal.',
  })
  orders!: PreparedOrderDto[];

  @ApiProperty({
    type: [String],
    description: 'Produits laissés de côté : sans fournisseur principal.',
  })
  withoutSupplier!: string[];

  @ApiProperty({
    description:
      'Lignes au prix 0 (dernier prix d’achat inconnu) : à compléter.',
  })
  unpricedLines!: number;
}
