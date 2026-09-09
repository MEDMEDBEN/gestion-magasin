import { Body, Controller, Get, HttpCode, HttpStatus, Post } from '@nestjs/common';
import { Throttle } from '@nestjs/throttler';
import {
  ApiBearerAuth,
  ApiOkResponse,
  ApiOperation,
  ApiTags,
  ApiUnauthorizedResponse,
} from '@nestjs/swagger';
import {
  AllowPasswordChange,
  CurrentUser,
  AuthenticatedUser,
  Public,
  RoleCode,
  Roles,
} from '../common/auth.decorators';
import { ErrorResponseDto } from '../common/dto/error-response.dto';
import { AuthService } from './auth.service';
import {
  AuthUserDto,
  ChangePasswordDto,
  LoginDto,
  LoginResponseDto,
  LogoutDto,
  RefreshDto,
} from './dto/auth.dto';

const ALL_ROLES = [RoleCode.ADMIN, RoleCode.VENDEUR, RoleCode.MAGASINIER];

/// Limites anti-brute-force, surchargeables par variable d'environnement
/// (les tests d'intégration enchaînent volontairement beaucoup de connexions).
const LOGIN_LIMIT = Number(process.env.AUTH_LOGIN_LIMIT ?? 10);
const REFRESH_LIMIT = Number(process.env.AUTH_REFRESH_LIMIT ?? 30);
const RATE_WINDOW_MS = 900_000; // 15 min

@ApiTags('Auth')
@Controller('auth')
export class AuthController {
  constructor(private readonly authService: AuthService) {}

  @Public()
  // Anti-brute-force : 10 tentatives / 15 min par IP par défaut.
  @Throttle({ default: { ttl: RATE_WINDOW_MS, limit: LOGIN_LIMIT } })
  @Post('login')
  @HttpCode(HttpStatus.OK)
  @ApiOperation({
    summary: 'Connexion par email ou téléphone',
    description:
      "Pas d'inscription publique : les comptes sont créés par l'admin. " +
      'Si `user.mustChangePassword` est vrai, seul /auth/change-password est accessible.',
  })
  @ApiOkResponse({ type: LoginResponseDto })
  @ApiUnauthorizedResponse({ type: ErrorResponseDto })
  login(@Body() dto: LoginDto): Promise<LoginResponseDto> {
    return this.authService.login(dto);
  }

  @Public()
  @Throttle({ default: { ttl: RATE_WINDOW_MS, limit: REFRESH_LIMIT } })
  @Post('refresh')
  @HttpCode(HttpStatus.OK)
  @ApiOperation({
    summary: 'Renouvelle les tokens (rotation)',
    description:
      'Le refresh présenté est révoqué et remplacé. Rejouer un token déjà révoqué ' +
      "ferme toutes les sessions de l'utilisateur.",
  })
  @ApiOkResponse({ type: LoginResponseDto })
  @ApiUnauthorizedResponse({ type: ErrorResponseDto })
  refresh(@Body() dto: RefreshDto): Promise<LoginResponseDto> {
    return this.authService.refresh(dto.refreshToken);
  }

  @Roles(...ALL_ROLES)
  @AllowPasswordChange()
  @Post('change-password')
  @HttpCode(HttpStatus.OK)
  @ApiBearerAuth()
  @ApiOperation({
    summary: 'Change le mot de passe (obligatoire à la première connexion)',
    description:
      'Lève `mustChangePassword`, révoque toutes les sessions et renvoie des tokens neufs.',
  })
  @ApiOkResponse({ type: LoginResponseDto })
  changePassword(
    @CurrentUser() user: AuthenticatedUser,
    @Body() dto: ChangePasswordDto,
  ): Promise<LoginResponseDto> {
    return this.authService.changePassword(user.id, dto);
  }

  @Roles(...ALL_ROLES)
  @AllowPasswordChange()
  @Post('logout')
  @HttpCode(HttpStatus.OK)
  @ApiBearerAuth()
  @ApiOperation({
    summary: 'Déconnexion — révoque un refresh token, ou toutes les sessions',
  })
  logout(
    @CurrentUser() user: AuthenticatedUser,
    @Body() dto: LogoutDto,
  ): Promise<{ revoked: number }> {
    return this.authService.logout(user.id, dto);
  }

  @Roles(...ALL_ROLES)
  // Accessible malgré `mustChangePassword` : l'app doit pouvoir dire QUI elle
  // affiche sur l'écran de changement de mot de passe. Ne rend que le profil
  // du demandeur — aucune action métier n'est déverrouillée pour autant.
  @AllowPasswordChange()
  @Get('me')
  @ApiBearerAuth()
  @ApiOperation({ summary: 'Profil, rôles et permissions effectives' })
  @ApiOkResponse({ type: AuthUserDto })
  me(@CurrentUser() user: AuthenticatedUser): Promise<AuthUserDto> {
    return this.authService.me(user.id);
  }
}
