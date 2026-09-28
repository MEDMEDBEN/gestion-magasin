import { ApiProperty } from '@nestjs/swagger';
import { Transform } from 'class-transformer';
import { IsOptional, IsString, MaxLength } from 'class-validator';

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
  @MaxLength(120)
  @IsOptional()
  name?: string | null;

  @Transform(trimOrNull)
  @IsString()
  @MaxLength(300)
  @IsOptional()
  address?: string | null;

  @Transform(trimOrNull)
  @IsString()
  @MaxLength(30)
  @IsOptional()
  phone?: string | null;

  @Transform(trimOrNull)
  @IsString()
  @MaxLength(40)
  @IsOptional()
  nif?: string | null;

  @Transform(trimOrNull)
  @IsString()
  @MaxLength(40)
  @IsOptional()
  rc?: string | null;

  @Transform(trimOrNull)
  @IsString()
  @MaxLength(40)
  @IsOptional()
  nis?: string | null;

  @Transform(trimOrNull)
  @IsString()
  @MaxLength(40)
  @IsOptional()
  ai?: string | null;
}
