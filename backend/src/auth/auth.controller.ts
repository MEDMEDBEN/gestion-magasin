import { Body, Controller, Get, HttpCode, HttpStatus, Ip, Post } from '@nestjs/common';
import { Throttle } from '@nestjs/throttler';
import {
  ApiBearerAuth,
  ApiForbiddenResponse,
  ApiOkResponse,
  ApiOperation,
  ApiTags,
  ApiTooManyRequestsResponse,
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
import { intFromEnv } from '../common/env';
import { normalizeIdentifier } from '../common/identifiers';
import { AuthService } from './auth.service';
import {
  AuthUserDto,
  ChangePasswordDto,
  LoginDto,
  LoginResponseDto,
  LogoutDto,
  LogoutResponseDto,
  RefreshDto,
} from './dto/auth.dto';

const ALL_ROLES = [RoleCode.ADMIN, RoleCode.VENDEUR, RoleCode.MAGASINIER];

/// Fenêtre des limites anti-brute-force. Les limites sont lues À CHAQUE requête
/// (surchargeables par variable d'environnement, validées au démarrage) : lues à
/// l'import du module, elles ignoreraient le `.env` chargé ensuite.
const RATE_WINDOW_MS = 900_000; // 15 min
const loginLimit = () => intFromEnv('AUTH_LOGIN_LIMIT', 10);
const refreshLimit = () => intFromEnv('AUTH_REFRESH_LIMIT', 30);
const changePasswordLimit = () => intFromEnv('AUTH_CHANGE_PASSWORD_LIMIT', 5);

/// Quota de connexion compté par IP ET par identifiant visé : tous les postes du
/// magasin sortent par la même IP — compté par IP seule, un employé malveillant
/// bloquerait les connexions de TOUT le magasin en échouant 10 fois (contre-audit
/// N10). Un attaquant reste limité à 10 essais / 15 min par compte et par IP.
const loginTracker = (req: { ip?: string; body?: { identifier?: unknown } }): string => {
  const identifier = normalizeIdentifier(req.body?.identifier);
  return `${req.ip}|${typeof identifier === 'string' ? identifier : ''}`;
};

@ApiTags('Auth')
@ApiTooManyRequestsResponse({ type: ErrorResponseDto, description: '`RATE_LIMITED`' })
@Controller('auth')
export class AuthController {
  constructor(private readonly authService: AuthService) {}

  @Public()
  // Anti-brute-force : 10 tentatives / 15 min par IP réelle (`configureApp`) et par compte.
  @Throttle({
    default: { ttl: RATE_WINDOW_MS, limit: loginLimit, getTracker: loginTracker },
  })
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
  @Throttle({ default: { ttl: RATE_WINDOW_MS, limit: refreshLimit } })
  @Post('refresh')
  @HttpCode(HttpStatus.OK)
  @ApiOperation({
    summary: 'Renouvelle les tokens (rotation)',
    description:
      'Le refresh présenté est révoqué et remplacé. Rejouer un token déjà révoqué ' +
      "ferme toutes les sessions de l'utilisateur (et le trace dans l'audit).",
  })
  @ApiOkResponse({ type: LoginResponseDto })
  @ApiUnauthorizedResponse({ type: ErrorResponseDto })
  refresh(@Body() dto: RefreshDto, @Ip() ip: string): Promise<LoginResponseDto> {
    return this.authService.refresh(dto.refreshToken, ip);
  }

  @Roles(...ALL_ROLES)
  @AllowPasswordChange()
  // Un appareil compromis ne doit pas pouvoir deviner le mot de passe actuel en boucle.
  @Throttle({ default: { ttl: RATE_WINDOW_MS, limit: changePasswordLimit } })
  @Post('change-password')
  @HttpCode(HttpStatus.OK)
  @ApiBearerAuth()
  @ApiOperation({
    summary: 'Change le mot de passe (obligatoire à la première connexion)',
    description:
      'Lève `mustChangePassword`, révoque toutes les sessions et renvoie des tokens neufs. ' +
      'Refusé pour un compte désactivé. Tracé dans l’audit (sans le secret).',
  })
  @ApiOkResponse({ type: LoginResponseDto })
  @ApiForbiddenResponse({
    type: ErrorResponseDto,
    description: '`CURRENT_PASSWORD_INVALID` ou `ACCOUNT_DISABLED`',
  })
  changePassword(
    @CurrentUser() user: AuthenticatedUser,
    @Body() dto: ChangePasswordDto,
    @Ip() ip: string,
  ): Promise<LoginResponseDto> {
    return this.authService.changePassword(user.id, dto, {
      userId: user.id,
      ipAddress: ip,
    });
  }

  /// Publique : le refresh token (256 bits) EST la preuve de possession. Un logout
  /// ne doit jamais dépendre d'un access token expiré (voir `LogoutDto`).
  @Public()
  @Throttle({ default: { ttl: RATE_WINDOW_MS, limit: refreshLimit } })
  @Post('logout')
  @HttpCode(HttpStatus.OK)
  @ApiOperation({
    summary: 'Déconnexion — ferme cette session, ou toutes (allDevices)',
  })
  @ApiOkResponse({ type: LogoutResponseDto })
  logout(@Body() dto: LogoutDto, @Ip() ip: string): Promise<LogoutResponseDto> {
    return this.authService.logout(dto, ip);
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
