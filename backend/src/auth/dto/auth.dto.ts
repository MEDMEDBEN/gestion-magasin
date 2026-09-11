import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import { Transform } from 'class-transformer';
import {
  IsBoolean,
  IsNotEmpty,
  IsOptional,
  IsString,
  MaxLength,
  MinLength,
} from 'class-validator';
import { EMAIL_MAX_LENGTH, normalizeIdentifier } from '../../common/identifiers';
import { PASSWORD_MAX_LENGTH, PASSWORD_MIN_LENGTH } from '../password';

/// Un refresh token fait 64 caractères hexadécimaux : au-delà, ce n'en est pas un.
const REFRESH_TOKEN_MAX_LENGTH = 128;
const DEVICE_FIELD_MAX_LENGTH = 100;

export class LoginDto {
  @ApiProperty({
    description: 'Email OU numéro de téléphone (normalisé : casse, espaces)',
    example: 'admin@magasin.dz',
  })
  @Transform(({ value }) => normalizeIdentifier(value))
  @IsString()
  @IsNotEmpty()
  @MaxLength(EMAIL_MAX_LENGTH)
  identifier!: string;

  @ApiProperty({ example: 'MotDePasse123!' })
  @IsString()
  @IsNotEmpty()
  @MaxLength(PASSWORD_MAX_LENGTH)
  password!: string;

  @ApiPropertyOptional({
    description:
      "Identifiant stable de l'appareil : une nouvelle connexion depuis le même " +
      'appareil ferme la session précédente de cet appareil.',
  })
  @IsString()
  @IsOptional()
  @MaxLength(DEVICE_FIELD_MAX_LENGTH)
  deviceId?: string;

  @ApiPropertyOptional({ example: 'Samsung A54 — Magasinier' })
  @IsString()
  @IsOptional()
  @MaxLength(DEVICE_FIELD_MAX_LENGTH)
  deviceName?: string;
}

export class RefreshDto {
  @ApiProperty({ description: 'Refresh token opaque reçu au login' })
  @IsString()
  @IsNotEmpty()
  @MaxLength(REFRESH_TOKEN_MAX_LENGTH)
  refreshToken!: string;
}

export class ChangePasswordDto {
  @ApiProperty()
  @IsString()
  @IsNotEmpty()
  @MaxLength(PASSWORD_MAX_LENGTH)
  currentPassword!: string;

  @ApiProperty({ minLength: PASSWORD_MIN_LENGTH, maxLength: PASSWORD_MAX_LENGTH })
  @IsString()
  @MinLength(PASSWORD_MIN_LENGTH, {
    message: 'Le nouveau mot de passe doit faire au moins 8 caractères',
  })
  @MaxLength(PASSWORD_MAX_LENGTH)
  newPassword!: string;

  @ApiPropertyOptional({
    description: 'Appareil courant : la session neuve lui reste rattachée.',
  })
  @IsString()
  @IsOptional()
  @MaxLength(DEVICE_FIELD_MAX_LENGTH)
  deviceId?: string;

  @ApiPropertyOptional()
  @IsString()
  @IsOptional()
  @MaxLength(DEVICE_FIELD_MAX_LENGTH)
  deviceName?: string;
}

/// Déconnexion. Route PUBLIQUE : le refresh token (secret de 256 bits) est la
/// preuve de possession de la session. Ainsi un logout ne dépend jamais d'un
/// access token expiré — sinon l'intercepteur rafraîchirait d'abord, et le
/// logout révoquerait l'ANCIEN token en laissant le neuf vivant 90 jours.
export class LogoutDto {
  @ApiProperty({ description: 'Refresh token de la session à fermer.' })
  @IsString()
  @IsNotEmpty()
  @MaxLength(REFRESH_TOKEN_MAX_LENGTH)
  refreshToken!: string;

  @ApiPropertyOptional({
    default: false,
    description:
      'Révoque TOUTES les sessions du titulaire de ce token (téléphone volé, départ).',
  })
  @IsBoolean()
  @IsOptional()
  allDevices?: boolean;
}

export class LogoutResponseDto {
  @ApiProperty({ example: 1, description: 'Nombre de sessions fermées' })
  revoked!: number;
}

export class AuthUserDto {
  @ApiProperty() id!: string;
  @ApiProperty({ nullable: true }) email!: string | null;
  @ApiProperty({ nullable: true }) phone!: string | null;
  @ApiProperty() fullName!: string;
  @ApiProperty({ type: [String] }) roles!: string[];
  @ApiProperty({ type: [String] }) permissions!: string[];
  @ApiProperty({ description: 'Si vrai, seul /auth/change-password est accessible' })
  mustChangePassword!: boolean;
}

export class TokensDto {
  @ApiProperty({ description: 'JWT signé, durée 15 min' }) accessToken!: string;
  @ApiProperty({ description: 'Token opaque, 90 j glissants, révocable' })
  refreshToken!: string;
  @ApiProperty({ example: 900, description: "Durée de vie de l'access token (secondes)" })
  expiresIn!: number;
}

export class LoginResponseDto extends TokensDto {
  @ApiProperty({ type: AuthUserDto }) user!: AuthUserDto;
}
