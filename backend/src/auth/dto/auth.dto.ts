import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import {
  IsBoolean,
  IsNotEmpty,
  IsOptional,
  IsString,
  MinLength,
} from 'class-validator';

export class LoginDto {
  @ApiProperty({
    description: 'Email OU numéro de téléphone',
    example: 'admin@magasin.dz',
  })
  @IsString()
  @IsNotEmpty()
  identifier!: string;

  @ApiProperty({ example: 'MotDePasse123!' })
  @IsString()
  @IsNotEmpty()
  password!: string;

  @ApiPropertyOptional({
    description: "Identifiant stable de l'appareil, pour révoquer une session précise",
  })
  @IsString()
  @IsOptional()
  deviceId?: string;

  @ApiPropertyOptional({ example: 'Samsung A54 — Magasinier' })
  @IsString()
  @IsOptional()
  deviceName?: string;
}

export class RefreshDto {
  @ApiProperty({ description: 'Refresh token opaque reçu au login' })
  @IsString()
  @IsNotEmpty()
  refreshToken!: string;
}

export class ChangePasswordDto {
  @ApiProperty()
  @IsString()
  @IsNotEmpty()
  currentPassword!: string;

  @ApiProperty({ minLength: 8 })
  @IsString()
  @MinLength(8, {
    message: 'Le nouveau mot de passe doit faire au moins 8 caractères',
  })
  newPassword!: string;
}

export class LogoutDto {
  @ApiPropertyOptional({
    description:
      'Refresh token à révoquer. Absent + allDevices=false → révoque la session courante.',
  })
  @IsString()
  @IsOptional()
  refreshToken?: string;

  @ApiPropertyOptional({
    default: false,
    description: 'Révoque TOUTES les sessions de l’utilisateur (téléphone volé, départ).',
  })
  @IsBoolean()
  @IsOptional()
  allDevices?: boolean;
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
