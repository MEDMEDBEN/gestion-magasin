import { ApiProperty } from '@nestjs/swagger';

export class ImportErrorDto {
  @ApiProperty({ description: 'Ligne du fichier (1 = première ligne).' })
  line!: number;
  @ApiProperty() message!: string;
}

/// Compte rendu d'un import : à blanc (`dryRun`), rien n'est écrit et les
/// erreurs sont listées ; appliqué, `created` fiches ont été créées d'un bloc.
export class ImportReportDto {
  @ApiProperty({ enum: ['products', 'customers', 'suppliers'] }) kind!: string;
  @ApiProperty() dryRun!: boolean;
  @ApiProperty({ description: 'Lignes non vides lues dans le fichier.' })
  total!: number;
  @ApiProperty({ description: 'Fiches créées (0 à blanc).' }) created!: number;
  @ApiProperty({ type: [ImportErrorDto] }) errors!: ImportErrorDto[];
}
