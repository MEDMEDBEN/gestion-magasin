import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import { Type } from 'class-transformer';
import { IsInt, IsOptional, Max, Min } from 'class-validator';
import { PaginationMetaDto } from '../../common/dto/pagination.dto';

/// Fenêtre d'analyse, en jours. Bornée des deux côtés : en dessous d'une
/// semaine un « produit dormant » ne veut rien dire, et au-delà de deux ans on
/// balaie un historique que ce magasin n'a pas encore.
class DaysQueryDto {
  @ApiPropertyOptional({ default: 120, minimum: 7, maximum: 730 })
  @Type(() => Number)
  @IsInt()
  @Min(7)
  @Max(730)
  @IsOptional()
  days = 120;
}

export class DormantQueryDto extends DaysQueryDto {
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
}

/// Fenêtre par défaut plus courte pour la demande : « ce qui se vend » se juge
/// sur un mois, pas sur quatre.
export class DemandQueryDto {
  @ApiPropertyOptional({ default: 30, minimum: 7, maximum: 730 })
  @Type(() => Number)
  @IsInt()
  @Min(7)
  @Max(730)
  @IsOptional()
  days = 30;
}

export class DormantProductDto {
  @ApiProperty() productId!: string;
  @ApiProperty() sku!: string;
  @ApiProperty() name!: string;
  @ApiProperty() unit!: string;

  @ApiProperty({
    description: 'Stock en MAGASIN + DÉPÔT (transit exclu).',
    example: '40.000',
  })
  quantity!: string;

  @ApiProperty({
    nullable: true,
    description:
      'Dernière vente de ce produit (ISO 8601). `null` = jamais vendu.',
  })
  lastSoldAt!: string | null;

  @ApiProperty({
    nullable: true,
    description: 'Dernier mouvement de stock, vente ou non (ISO 8601).',
  })
  lastMovementAt!: string | null;

  @ApiProperty({
    nullable: true,
    description:
      'Valeur du stock qui dort, en centimes : quantité × dernier prix ' +
      'd’achat. `null` si le produit n’a jamais été réceptionné.',
  })
  sleepingValueHt!: number | null;
}

export class DormantProductListDto {
  @ApiProperty({ type: [DormantProductDto] }) data!: DormantProductDto[];
  @ApiProperty({ type: PaginationMetaDto }) meta!: PaginationMetaDto;

  @ApiProperty({ description: 'Seuil de dormance appliqué, en jours.' })
  days!: number;

  @ApiProperty({
    nullable: true,
    description:
      'Valeur totale du stock dormant, en centimes. Les produits sans prix ' +
      'connu n’y entrent pas.',
  })
  totalSleepingValueHt!: number | null;
}

export class DemandLineDto {
  @ApiProperty() productId!: string;
  @ApiProperty() sku!: string;
  @ApiProperty() name!: string;
  @ApiProperty() unit!: string;

  @ApiProperty({
    description: 'La grandeur mesurée par cette liste (quantité décimale).',
    example: '124.000',
  })
  quantity!: string;

  @ApiProperty({
    nullable: true,
    description:
      'Chiffre d’affaires HT en centimes, seulement sur « les plus vendus » ' +
      'ET seulement pour l’ADMIN. `null` pour les autres rôles : le tableau ' +
      'de bord ne montre à un vendeur que SES ventes, ce rapport ne le ' +
      'contourne pas. `null` ne veut donc PAS dire « rien vendu ».',
  })
  revenueHt!: number | null;
}

export class ProductDemandDto {
  @ApiProperty({ description: 'Fenêtre d’analyse appliquée, en jours.' })
  days!: number;

  @ApiProperty({
    type: [DemandLineDto],
    description: 'Les plus vendus sur la période (ventes VALIDÉES).',
  })
  bestSellers!: DemandLineDto[];

  @ApiProperty({
    type: [DemandLineDto],
    description: 'Les plus demandés au dépôt (quantités demandées).',
  })
  mostRequested!: DemandLineDto[];

  @ApiProperty({
    type: [DemandLineDto],
    description:
      'Demandés au dépôt et NON servis : ce qui manquait à la préparation. ' +
      'C’est la demande commerciale qu’une rupture a fait perdre (spec §20).',
  })
  unmetDemand!: DemandLineDto[];
}
