import { ApiProperty } from '@nestjs/swagger';
import { Transform } from 'class-transformer';
import { IsOptional, IsString, Matches, MaxLength } from 'class-validator';

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
}
