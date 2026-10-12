import { ApiProperty } from '@nestjs/swagger';
import { Transform } from 'class-transformer';
import {
  IsIn,
  IsInt,
  IsOptional,
  IsString,
  Matches,
  Max,
  MaxLength,
  Min,
} from 'class-validator';
import {
  DOCUMENT_PAPERS,
  type DocumentPaper,
  TICKET_PAPERS,
  type TicketPaper,
} from '../store-settings';

/// Imprimable par les polices standard des PDF (jeu WinAnsi : latin, accents,
/// €, guillemets…), sur UNE ligne. L'arabe n'y est pas : refusé plutôt
/// qu'imprimé illisible sur une facture (police à embarquer : décision en
/// attente, docs/tasks.md).
const PRINTABLE = /^[ -~ -ÿ‘’“”–—…€Œœ]*$/;
const PRINTABLE_MESSAGE =
  'caractères non imprimables sur les documents (arabe, emoji, retour à la ligne…)';

/// Vide → `null` : le champ retombe sur la variable d'environnement.
const trimOrNull = ({ value }: { value: unknown }) =>
  typeof value === 'string' ? value.trim() || null : value;

export class StoreSettingsDto {
  @ApiProperty({ nullable: true, example: 'Électricité El Nour' })
  name!: string | null;
  @ApiProperty({ nullable: true }) address!: string | null;
  @ApiProperty({ nullable: true }) phone!: string | null;
  @ApiProperty({ nullable: true, description: 'NIF' }) nif!: string | null;
  @ApiProperty({ nullable: true, description: 'Registre du commerce' })
  rc!: string | null;
  @ApiProperty({ nullable: true, description: 'NIS' }) nis!: string | null;
  @ApiProperty({ nullable: true, description: 'Article d’imposition' })
  ai!: string | null;
  @ApiProperty({ nullable: true }) email!: string | null;
  @ApiProperty({
    nullable: true,
    description: 'Pied de page des bons et tickets.',
  })
  footer!: string | null;
  @ApiProperty({ enum: TICKET_PAPERS, description: 'Format des tickets.' })
  ticketPaper!: TicketPaper;
  @ApiProperty({
    enum: DOCUMENT_PAPERS,
    description: 'Format des factures, devis, bons et bordereaux.',
  })
  documentPaper!: DocumentPaper;
  @ApiProperty({ description: 'Largeur de l’étiquette en rouleau (mm).' })
  labelWidthMm!: number;
  @ApiProperty({ description: 'Hauteur de l’étiquette en rouleau (mm).' })
  labelHeightMm!: number;
}

/// Tous les champs sont facultatifs : seuls ceux envoyés changent.
export class UpdateStoreSettingsDto {
  @Transform(trimOrNull)
  @IsString()
  @Matches(PRINTABLE, { message: `$property : ${PRINTABLE_MESSAGE}` })
  @MaxLength(120)
  @IsOptional()
  name?: string | null;

  @Transform(trimOrNull)
  @IsString()
  @Matches(PRINTABLE, { message: `$property : ${PRINTABLE_MESSAGE}` })
  @MaxLength(300)
  @IsOptional()
  address?: string | null;

  @Transform(trimOrNull)
  @IsString()
  @Matches(PRINTABLE, { message: `$property : ${PRINTABLE_MESSAGE}` })
  @MaxLength(30)
  @IsOptional()
  phone?: string | null;

  @Transform(trimOrNull)
  @IsString()
  @Matches(PRINTABLE, { message: `$property : ${PRINTABLE_MESSAGE}` })
  @MaxLength(40)
  @IsOptional()
  nif?: string | null;

  @Transform(trimOrNull)
  @IsString()
  @Matches(PRINTABLE, { message: `$property : ${PRINTABLE_MESSAGE}` })
  @MaxLength(40)
  @IsOptional()
  rc?: string | null;

  @Transform(trimOrNull)
  @IsString()
  @Matches(PRINTABLE, { message: `$property : ${PRINTABLE_MESSAGE}` })
  @MaxLength(40)
  @IsOptional()
  nis?: string | null;

  @Transform(trimOrNull)
  @IsString()
  @Matches(PRINTABLE, { message: `$property : ${PRINTABLE_MESSAGE}` })
  @MaxLength(40)
  @IsOptional()
  ai?: string | null;

  @Transform(trimOrNull)
  @IsString()
  @Matches(PRINTABLE, { message: `$property : ${PRINTABLE_MESSAGE}` })
  @MaxLength(120)
  @IsOptional()
  email?: string | null;

  @Transform(trimOrNull)
  @IsString()
  @Matches(PRINTABLE, { message: `$property : ${PRINTABLE_MESSAGE}` })
  @MaxLength(200)
  @IsOptional()
  footer?: string | null;

  @IsIn(TICKET_PAPERS)
  @IsOptional()
  ticketPaper?: TicketPaper;

  @IsIn(DOCUMENT_PAPERS)
  @IsOptional()
  documentPaper?: DocumentPaper;

  /// Étiquettes de 20 à 150 mm : de la petite étiquette de prix au grand
  /// format colis.
  @IsInt()
  @Min(20)
  @Max(150)
  @IsOptional()
  labelWidthMm?: number;

  @IsInt()
  @Min(15)
  @Max(150)
  @IsOptional()
  labelHeightMm?: number;
}
