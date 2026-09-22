import { ApiProperty } from '@nestjs/swagger';

/// Un bloc ABSENT (`null`) = le compte n'a pas le droit de le voir. L'écran
/// n'affiche alors rien, jamais un zéro (qui se lirait « aucune alerte »).

export class DashboardSalesDto {
  @ApiProperty({
    description: 'Ventes validées du jour (les miennes ; toutes pour l’admin).',
  })
  count!: number;
  @ApiProperty({ description: 'Chiffre d’affaires TTC du jour, en centimes.' })
  revenueTtc!: number;
}

export class DashboardLowStockDto {
  @ApiProperty() productId!: string;
  @ApiProperty() name!: string;
  @ApiProperty({ example: '3.000' }) quantity!: string;
  @ApiProperty({ example: '10.000' }) minThreshold!: string;
}

export class DashboardStockDto {
  @ApiProperty({ description: 'Produits au niveau du seuil ou en dessous.' })
  lowCount!: number;
  @ApiProperty({ description: 'Produits actifs à zéro (ou négatif) partout.' })
  outOfStockCount!: number;
  @ApiProperty({
    type: [DashboardLowStockDto],
    description:
      'Les plus urgents seulement — la liste complète est dans Stock.',
  })
  low!: DashboardLowStockDto[];
}

export class DashboardTransfersDto {
  @ApiProperty({
    description: 'Demandes à traiter (demandée, acceptée, en préparation).',
  })
  toPrepare!: number;
  @ApiProperty({ description: 'Préparées ou en route, pas encore reçues.' })
  inTransit!: number;
}

export class DashboardPurchasesDto {
  @ApiProperty({
    description:
      'Commandes confirmées restant à recevoir (même partiellement).',
  })
  toReceive!: number;
}

export class DashboardCustomersDto {
  @ApiProperty({ description: 'Total dû par les clients, en centimes.' })
  debt!: number;
  @ApiProperty({ description: 'Part échue de cette dette, en centimes.' })
  overdue!: number;
}

export class DashboardSuppliersDto {
  @ApiProperty({ description: 'Total dû aux fournisseurs, en centimes.' })
  debt!: number;
}

export class DashboardTasksDto {
  @ApiProperty({ description: 'Mes tâches non terminées.' }) open!: number;
  @ApiProperty({
    description: 'Mes tâches non terminées dont l’échéance est passée.',
  })
  late!: number;
}

export class DashboardDto {
  @ApiProperty({
    example: '2026-09-23',
    description: 'Journée locale (Alger) résumée.',
  })
  day!: string;
  @ApiProperty({ type: DashboardSalesDto, nullable: true })
  sales!: DashboardSalesDto | null;
  @ApiProperty({ type: DashboardStockDto, nullable: true })
  stock!: DashboardStockDto | null;
  @ApiProperty({ type: DashboardTransfersDto, nullable: true })
  transfers!: DashboardTransfersDto | null;
  @ApiProperty({ type: DashboardPurchasesDto, nullable: true })
  purchases!: DashboardPurchasesDto | null;
  @ApiProperty({ type: DashboardCustomersDto, nullable: true })
  customers!: DashboardCustomersDto | null;
  @ApiProperty({ type: DashboardSuppliersDto, nullable: true })
  suppliers!: DashboardSuppliersDto | null;
  @ApiProperty({ type: DashboardTasksDto, nullable: true })
  tasks!: DashboardTasksDto | null;
}
