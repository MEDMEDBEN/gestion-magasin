import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import { Transform } from 'class-transformer';
import {
  ArrayNotEmpty,
  ArrayUnique,
  IsArray,
  IsBoolean,
  IsEmail,
  IsEnum,
  IsIn,
  IsOptional,
  IsString,
  Matches,
  MaxLength,
  MinLength,
} from 'class-validator';
import { PASSWORD_MAX_LENGTH, PASSWORD_MIN_LENGTH } from '../../auth/password';
import { RoleCode } from '../../common/auth.decorators';
import { PaginationMetaDto } from '../../common/dto/pagination.dto';
import {
  EMAIL_MAX_LENGTH,
  normalizeEmail,
  normalizePhone,
  PHONE_PATTERN,
} from '../../common/identifiers';
import { PERMISSIONS } from '../../common/permissions';
import { IsOptionalNotNull } from '../../common/validation';

/// Codes de permission acceptés — refuse un code inconnu par un 400 métier
/// plutôt que par une 500 Prisma au moment du `connect`.
const PERMISSION_CODES = Object.values(PERMISSIONS);

const FULL_NAME_MAX_LENGTH = 100;
const PHONE_MESSAGE =
  'Téléphone invalide : 6 à 15 chiffres, « + » international accepté';
const trim = ({ value }: { value: unknown }) =>
  typeof value === 'string' ? value.trim() : value;

export class CreateUserDto {
  @ApiPropertyOptional({
    example: 'vendeur@magasin.dz',
    description: 'Stocké en minuscules, sans espaces.',
  })
  @Transform(({ value }) => normalizeEmail(value))
  @IsOptional()
  @IsEmail({}, { message: 'Email invalide' })
  @MaxLength(EMAIL_MAX_LENGTH)
  email?: string;

  @ApiPropertyOptional({
    example: '+213555000111',
    description: 'Espaces, points, tirets et parenthèses sont retirés.',
  })
  @Transform(({ value }) => normalizePhone(value))
  @IsOptional()
  @Matches(PHONE_PATTERN, { message: PHONE_MESSAGE })
  phone?: string;

  @ApiProperty({ example: 'Amine Benali' })
  @Transform(trim)
  @IsString()
  @MinLength(2)
  @MaxLength(FULL_NAME_MAX_LENGTH)
  fullName!: string;

  @ApiProperty({
    minLength: PASSWORD_MIN_LENGTH,
    maxLength: PASSWORD_MAX_LENGTH,
    description: "Mot de passe temporaire — l'utilisateur devra le changer.",
  })
  @IsString()
  @MinLength(PASSWORD_MIN_LENGTH)
  @MaxLength(PASSWORD_MAX_LENGTH)
  temporaryPassword!: string;

  @ApiProperty({ enum: RoleCode, isArray: true, example: [RoleCode.VENDEUR] })
  @IsArray()
  @ArrayNotEmpty({ message: 'Au moins un rôle est obligatoire' })
  @ArrayUnique()
  @IsEnum(RoleCode, { each: true })
  roles!: RoleCode[];

  @ApiPropertyOptional({
    type: [String],
    enum: PERMISSION_CODES,
    description:
      'Permissions accordées EN PLUS de celles des rôles (cumul). Les permissions ' +
      'réservées à l’ADMIN ne peuvent pas être accordées à un autre rôle.',
  })
  @IsOptional()
  @IsArray()
  @ArrayUnique()
  @IsIn(PERMISSION_CODES, { each: true })
  extraPermissions?: string[];
}

/// Modification partielle. Chaque champ est facultatif mais JAMAIS `null` :
/// `null` effacerait un identifiant de connexion ou provoquerait une 500.
export class UpdateUserDto {
  @ApiPropertyOptional()
  @Transform(trim)
  @IsOptionalNotNull()
  @IsString()
  @MinLength(2)
  @MaxLength(FULL_NAME_MAX_LENGTH)
  fullName?: string;

  @ApiPropertyOptional()
  @Transform(({ value }) => normalizeEmail(value))
  @IsOptionalNotNull()
  @IsEmail({}, { message: 'Email invalide' })
  @MaxLength(EMAIL_MAX_LENGTH)
  email?: string;

  @ApiPropertyOptional()
  @Transform(({ value }) => normalizePhone(value))
  @IsOptionalNotNull()
  @IsString()
  @Matches(PHONE_PATTERN, { message: PHONE_MESSAGE })
  phone?: string;

  @ApiPropertyOptional()
  @IsOptionalNotNull()
  @IsBoolean()
  isActive?: boolean;

  @ApiPropertyOptional({ enum: RoleCode, isArray: true })
  @IsOptionalNotNull()
  @IsArray()
  @ArrayNotEmpty({ message: 'Au moins un rôle est obligatoire' })
  @ArrayUnique()
  @IsEnum(RoleCode, { each: true })
  roles?: RoleCode[];

  @ApiPropertyOptional({
    type: [String],
    enum: PERMISSION_CODES,
    description: 'Remplace les permissions accordées à la carte (`[]` = aucune).',
  })
  @IsOptionalNotNull()
  @IsArray()
  @ArrayUnique()
  @IsIn(PERMISSION_CODES, { each: true })
  extraPermissions?: string[];
}

export class ResetPasswordDto {
  @ApiProperty({
    minLength: PASSWORD_MIN_LENGTH,
    maxLength: PASSWORD_MAX_LENGTH,
    description: 'Nouveau mot de passe temporaire',
  })
  @IsString()
  @MinLength(PASSWORD_MIN_LENGTH)
  @MaxLength(PASSWORD_MAX_LENGTH)
  temporaryPassword!: string;
}

export class UserDto {
  @ApiProperty() id!: string;
  @ApiProperty({ nullable: true }) email!: string | null;
  @ApiProperty({ nullable: true }) phone!: string | null;
  @ApiProperty() fullName!: string;
  @ApiProperty() isActive!: boolean;
  @ApiProperty() mustChangePassword!: boolean;
  @ApiProperty({ type: [String] }) roles!: string[];
  @ApiProperty({
    type: [String],
    description: 'Permissions accordées à la carte, EN PLUS des rôles.',
  })
  extraPermissions!: string[];
  @ApiProperty({
    type: [String],
    description: 'Permissions EFFECTIVES (rôles + accordées à la carte).',
  })
  permissions!: string[];
  @ApiProperty({ nullable: true }) lastLoginAt!: Date | null;
  @ApiProperty() createdAt!: Date;
}

export class UserListDto {
  @ApiProperty({ type: [UserDto] }) data!: UserDto[];
  @ApiProperty({ type: PaginationMetaDto }) meta!: PaginationMetaDto;
}

export class RevokedSessionsDto {
  @ApiProperty({ example: 2, description: 'Nombre de sessions fermées' })
  revoked!: number;
}

export class PermissionInfoDto {
  @ApiProperty({ example: 'stock.loss' }) code!: string;
  @ApiProperty() description!: string;
  @ApiProperty({
    description: 'Réservée à l’ADMIN : non attribuable à la carte à un autre rôle.',
  })
  adminOnly!: boolean;
}

export class RoleInfoDto {
  @ApiProperty({ enum: RoleCode }) code!: RoleCode;
  @ApiProperty({ example: 'Magasinier' }) name!: string;
  @ApiProperty({ type: [String], description: 'Permissions incluses par le rôle' })
  permissions!: string[];
}

/// Catalogue servi à l'écran de gestion des comptes : l'app n'a pas à recopier
/// la matrice de `docs/permissions.md` (une seule source : `permissions.ts`).
export class PermissionCatalogDto {
  @ApiProperty({ type: [RoleInfoDto] }) roles!: RoleInfoDto[];
  @ApiProperty({ type: [PermissionInfoDto] }) permissions!: PermissionInfoDto[];
}
