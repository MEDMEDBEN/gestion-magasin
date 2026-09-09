import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import {
  ArrayNotEmpty,
  IsArray,
  IsBoolean,
  IsEmail,
  IsEnum,
  IsIn,
  IsOptional,
  IsString,
  MinLength,
  ValidateIf,
} from 'class-validator';
import { RoleCode } from '../../common/auth.decorators';
import { PERMISSIONS } from '../../common/permissions';

/// Codes de permission acceptés — refuse un code inconnu par un 400 métier
/// plutôt que par une 500 Prisma au moment du `connect`.
const PERMISSION_CODES = Object.values(PERMISSIONS);

export class CreateUserDto {
  @ApiPropertyOptional({ example: 'vendeur@magasin.dz' })
  @IsEmail({}, { message: 'Email invalide' })
  @IsOptional()
  email?: string;

  @ApiPropertyOptional({ example: '+213555000111' })
  @IsString()
  @IsOptional()
  phone?: string;

  /// Au moins un identifiant de connexion est obligatoire.
  @ValidateIf((dto: CreateUserDto) => !dto.email && !dto.phone)
  @IsString({ message: 'Fournir au moins un email ou un téléphone' })
  readonly identifierGuard?: string;

  @ApiProperty({ example: 'Amine Benali' })
  @IsString()
  @MinLength(2)
  fullName!: string;

  @ApiProperty({
    minLength: 8,
    description: "Mot de passe temporaire — l'utilisateur devra le changer.",
  })
  @IsString()
  @MinLength(8)
  temporaryPassword!: string;

  @ApiProperty({ enum: RoleCode, isArray: true, example: [RoleCode.VENDEUR] })
  @IsArray()
  @ArrayNotEmpty({ message: 'Au moins un rôle est obligatoire' })
  @IsEnum(RoleCode, { each: true })
  roles!: RoleCode[];

  @ApiPropertyOptional({
    type: [String],
    description: 'Permissions accordées EN PLUS de celles du rôle (cumul).',
  })
  @IsArray()
  @IsIn(PERMISSION_CODES, { each: true })
  @IsOptional()
  extraPermissions?: string[];
}

export class UpdateUserDto {
  @ApiPropertyOptional() @IsString() @MinLength(2) @IsOptional() fullName?: string;
  @ApiPropertyOptional() @IsEmail() @IsOptional() email?: string;
  @ApiPropertyOptional() @IsString() @IsOptional() phone?: string;
  @ApiPropertyOptional() @IsBoolean() @IsOptional() isActive?: boolean;

  @ApiPropertyOptional({ enum: RoleCode, isArray: true })
  @IsArray()
  @IsEnum(RoleCode, { each: true })
  @IsOptional()
  roles?: RoleCode[];

  @ApiPropertyOptional({ type: [String], enum: PERMISSION_CODES })
  @IsArray()
  @IsIn(PERMISSION_CODES, { each: true })
  @IsOptional()
  extraPermissions?: string[];
}

export class ResetPasswordDto {
  @ApiProperty({ minLength: 8, description: 'Nouveau mot de passe temporaire' })
  @IsString()
  @MinLength(8)
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
  @ApiProperty({ type: [String] }) permissions!: string[];
  @ApiProperty({ nullable: true }) lastLoginAt!: Date | null;
  @ApiProperty() createdAt!: Date;
}

export class UserListDto {
  @ApiProperty({ type: [UserDto] }) data!: UserDto[];
  @ApiProperty() meta!: { page: number; limit: number; total: number };
}
