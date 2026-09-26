import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import { IsISO8601, IsOptional } from 'class-validator';

/// Période d'un rapport. Bornes INCLUSIVES sur le jour : `from=2026-09-01` et
/// `to=2026-09-30` couvrent tout septembre, ce qu'un utilisateur attend quand il
/// demande « le mois de septembre ».
///
/// Absentes : les 30 derniers jours. Un rapport sans période serait un rapport
/// sur tout l'historique, donc un scan complet à chaque appel.
export class ReportPeriodQueryDto {
  @ApiPropertyOptional({
    description: 'Début de période (AAAA-MM-JJ), inclus. Défaut : J−30.',
    example: '2026-09-01',
  })
  @IsISO8601()
  @IsOptional()
  from?: string;

  @ApiPropertyOptional({
    description: 'Fin de période (AAAA-MM-JJ), INCLUSE. Défaut : aujourd’hui.',
    example: '2026-09-30',
  })
  @IsISO8601()
  @IsOptional()
  to?: string;
}

export class ReportPeriodDto {
  @ApiProperty({ example: '2026-09-01' }) from!: string;
  @ApiProperty({ example: '2026-09-30' }) to!: string;
  @ApiProperty({ description: 'Nombre de jours couverts, bornes incluses.' })
  days!: number;
}

export class SalesReportTotalsDto {
  @ApiProperty({ description: 'Nombre de ventes VALIDÉES.' }) count!: number;
  @ApiProperty({ description: 'Chiffre d’affaires HT, en centimes.' })
  revenueHt!: number;
  @ApiProperty({ description: 'TVA collectée, en centimes.' })
  taxAmount!: number;
  @ApiProperty({ description: 'Chiffre d’affaires TTC, en centimes.' })
  revenueTtc!: number;
  @ApiProperty({ description: 'Remises accordées, en centimes.' })
  discountAmount!: number;

  @ApiProperty({
    nullable: true,
    description:
      'Coût des marchandises vendues, en centimes : quantités vendues × ' +
      'DERNIER prix d’achat (règle 5). `null` si aucun produit vendu n’a de ' +
      'coût connu.',
  })
  costHt!: number | null;

  @ApiProperty({
    nullable: true,
    description:
      'Marge HT en centimes = CA HT − coût. `null` quand le coût est inconnu : ' +
      'une marge égale au CA serait un chiffre faux et flatteur.',
  })
  marginHt!: number | null;
}

export class SalesByDayDto {
  @ApiProperty({ example: '2026-09-14' }) date!: string;
  @ApiProperty() count!: number;
  @ApiProperty({ description: 'CA HT du jour, en centimes.' })
  revenueHt!: number;
}

export class SalesByCategoryDto {
  @ApiProperty({ nullable: true, description: '`null` = sans catégorie.' })
  categoryId!: string | null;
  @ApiProperty() categoryName!: string;
  @ApiProperty({ description: 'CA HT de la catégorie, en centimes.' })
  revenueHt!: number;
  @ApiProperty({
    description: 'Quantité vendue (décimale).',
    example: '124.000',
  })
  quantity!: string;
}

export class SalesReportDto {
  @ApiProperty({ type: ReportPeriodDto }) period!: ReportPeriodDto;
  @ApiProperty({ type: SalesReportTotalsDto }) totals!: SalesReportTotalsDto;

  @ApiProperty({
    type: [SalesByDayDto],
    description: 'Un point par jour AYANT eu des ventes, par date croissante.',
  })
  byDay!: SalesByDayDto[];

  @ApiProperty({
    type: [SalesByCategoryDto],
    description: 'Par catégorie, CA décroissant.',
  })
  byCategory!: SalesByCategoryDto[];
}

export class StockByLocationDto {
  @ApiProperty() locationId!: string;
  @ApiProperty() locationName!: string;
  @ApiProperty({ enum: ['MAGASIN', 'DEPOT'] }) locationType!: string;
  @ApiProperty({ description: 'Nombre de références en stock (quantité > 0).' })
  referenceCount!: number;
  @ApiProperty({
    nullable: true,
    description: 'Valeur au dernier prix d’achat, en centimes.',
  })
  valueHt!: number | null;
}

export class StockReportDto {
  @ApiProperty({
    description: 'Produits actifs ayant du stock (quantité > 0).',
  })
  referenceCount!: number;

  @ApiProperty({
    nullable: true,
    description:
      'Valeur totale du stock au dernier prix d’achat, en centimes. Les ' +
      'produits sans coût connu n’y entrent pas — `null` si aucun n’en a.',
  })
  valueHt!: number | null;

  @ApiProperty({
    description: 'Références sans coût connu, donc absentes de la valeur.',
  })
  withoutCostCount!: number;

  @ApiProperty({ description: 'Produits sous leur seuil minimum.' })
  lowCount!: number;

  @ApiProperty({ description: 'Produits à zéro ou en négatif.' })
  outOfStockCount!: number;

  @ApiProperty({
    type: [StockByLocationDto],
    description: 'Magasin et dépôt. Le transit est exclu.',
  })
  byLocation!: StockByLocationDto[];
}

export class PurchasesBySupplierDto {
  @ApiProperty() supplierId!: string;
  @ApiProperty() supplierName!: string;
  @ApiProperty({ description: 'Commandes passées sur la période.' })
  orderCount!: number;
  @ApiProperty({ description: 'Montant commandé HT, en centimes.' })
  orderedHt!: number;
  @ApiProperty({
    description: 'Montant réellement réceptionné HT, en centimes.',
  })
  receivedHt!: number;
}

export class PurchasesReportDto {
  @ApiProperty({ type: ReportPeriodDto }) period!: ReportPeriodDto;

  @ApiProperty({
    description:
      'Commandes passées sur la période, brouillons et annulées exclus.',
  })
  orderCount!: number;

  @ApiProperty({ description: 'Montant commandé HT, en centimes.' })
  orderedHt!: number;

  @ApiProperty({
    description:
      'Montant réceptionné HT sur la période, en centimes. Il ne correspond ' +
      'PAS au montant commandé : une commande de septembre peut être reçue en ' +
      'octobre, et une réception de septembre venir d’une commande d’août.',
  })
  receivedHt!: number;

  @ApiProperty({ description: 'Nombre de réceptions sur la période.' })
  receptionCount!: number;

  @ApiProperty({
    type: [PurchasesBySupplierDto],
    description: 'Par fournisseur, montant commandé décroissant.',
  })
  bySupplier!: PurchasesBySupplierDto[];
}
