import {
  Body,
  Controller,
  Get,
  HttpCode,
  HttpStatus,
  Ip,
  Param,
  Patch,
  Post,
  Query,
  UseGuards,
} from '@nestjs/common';
import {
  ApiBearerAuth,
  ApiConflictResponse,
  ApiCreatedResponse,
  ApiForbiddenResponse,
  ApiOkResponse,
  ApiOperation,
  ApiTags,
  ApiUnprocessableEntityResponse,
} from '@nestjs/swagger';
import { ActorContext } from '../audit/audit-writer';
import {
  AuthenticatedUser,
  CurrentUser,
  RequirePermissions,
  RoleCode,
  Roles,
} from '../common/auth.decorators';
import { CanonicalUuidPipe } from '../common/canonical-uuid.pipe';
import { ErrorResponseDto } from '../common/dto/error-response.dto';
import { PaginationQueryDto } from '../common/dto/pagination.dto';
import { FreshAccessGuard } from '../common/fresh-access.guard';
import { PERMISSIONS } from '../common/permissions';
import {
  CreateUserDto,
  PermissionCatalogDto,
  ResetPasswordDto,
  RevokedSessionsDto,
  UpdateUserDto,
  UserDto,
  UserListDto,
} from './dto/user.dto';
import { UsersService } from './users.service';

/// Toute la gestion des comptes est réservée à l'ADMIN (docs/permissions.md § Administration).
///
/// `FreshAccessGuard` : l'accès est relu EN BASE à chaque appel, pas seulement
/// dans le token — un admin désactivé ou rétrogradé perd la main immédiatement.
@ApiTags('Utilisateurs')
@ApiBearerAuth()
@ApiForbiddenResponse({ type: ErrorResponseDto })
@Roles(RoleCode.ADMIN)
@RequirePermissions(PERMISSIONS.USER_MANAGE)
@UseGuards(FreshAccessGuard)
@Controller('users')
export class UsersController {
  constructor(private readonly usersService: UsersService) {}

  @Post()
  @ApiOperation({
    summary: 'Crée un utilisateur (admin uniquement)',
    description:
      "Pas d'inscription publique. Le mot de passe fourni est temporaire : " +
      '`mustChangePassword` est forcé à vrai.',
  })
  @ApiCreatedResponse({ type: UserDto })
  @ApiConflictResponse({ type: ErrorResponseDto })
  @ApiUnprocessableEntityResponse({
    type: ErrorResponseDto,
    description: '`PERMISSION_NOT_GRANTABLE` — permission non attribuable à la carte',
  })
  create(
    @Body() dto: CreateUserDto,
    @CurrentUser() actor: AuthenticatedUser,
    @Ip() ip: string,
  ): Promise<UserDto> {
    return this.usersService.create(dto, UsersController.actorOf(actor, ip));
  }

  @Get()
  @ApiOperation({ summary: 'Liste paginée des utilisateurs' })
  @ApiOkResponse({ type: UserListDto })
  findAll(@Query() query: PaginationQueryDto): Promise<UserListDto> {
    return this.usersService.findAll(query);
  }

  /// Déclarée AVANT `:id` : sinon Express la prendrait pour un identifiant.
  @Get('permission-catalog')
  @ApiOperation({
    summary: 'Rôles et permissions attribuables',
    description: 'Lu dans la matrice validée (docs/permissions.md) — source unique.',
  })
  @ApiOkResponse({ type: PermissionCatalogDto })
  permissionCatalog(): PermissionCatalogDto {
    return this.usersService.permissionCatalog();
  }

  @Get(':id')
  @ApiOperation({ summary: 'Détail d’un utilisateur' })
  @ApiOkResponse({ type: UserDto })
  findOne(@Param('id', CanonicalUuidPipe) id: string): Promise<UserDto> {
    return this.usersService.findOne(id);
  }

  @Patch(':id')
  @ApiOperation({
    summary: 'Modifie un utilisateur (rôles, permissions, activation)',
    description:
      'Désactiver un compte révoque immédiatement toutes ses sessions. Un admin ne ' +
      'modifie ni ses propres rôles/permissions ni sa propre activation.',
  })
  @ApiOkResponse({ type: UserDto })
  @ApiConflictResponse({ type: ErrorResponseDto, description: '`LAST_ACTIVE_ADMIN`' })
  @ApiForbiddenResponse({
    type: ErrorResponseDto,
    description:
      '`SELF_MODIFICATION_FORBIDDEN` — un admin ne modifie ni ses rôles/permissions ' +
      'ni sa propre activation',
  })
  @ApiUnprocessableEntityResponse({
    type: ErrorResponseDto,
    description: '`PERMISSION_NOT_GRANTABLE` — permission non attribuable à la carte',
  })
  update(
    @Param('id', CanonicalUuidPipe) id: string,
    @Body() dto: UpdateUserDto,
    @CurrentUser() actor: AuthenticatedUser,
    @Ip() ip: string,
  ): Promise<UserDto> {
    return this.usersService.update(id, dto, UsersController.actorOf(actor, ip));
  }

  @Post(':id/reset-password')
  @HttpCode(HttpStatus.OK)
  @ApiOperation({
    summary: 'Réinitialise le mot de passe',
    description: 'Repose un mot de passe temporaire et coupe toutes les sessions.',
  })
  @ApiOkResponse({ type: UserDto })
  resetPassword(
    @Param('id', CanonicalUuidPipe) id: string,
    @Body() dto: ResetPasswordDto,
    @CurrentUser() actor: AuthenticatedUser,
    @Ip() ip: string,
  ): Promise<UserDto> {
    return this.usersService.resetPassword(
      id,
      dto,
      UsersController.actorOf(actor, ip),
    );
  }

  @Post(':id/revoke-sessions')
  @HttpCode(HttpStatus.OK)
  @ApiOperation({
    summary: 'Révoque toutes les sessions (téléphone volé, départ)',
    description:
      'Plus aucun renouvellement de session possible. Les routes sensibles refusent ' +
      'aussitôt les tokens de ces sessions ; les autres les acceptent au plus 15 min.',
  })
  @ApiOkResponse({ type: RevokedSessionsDto })
  revokeSessions(
    @Param('id', CanonicalUuidPipe) id: string,
    @CurrentUser() actor: AuthenticatedUser,
    @Ip() ip: string,
  ): Promise<RevokedSessionsDto> {
    return this.usersService.revokeSessions(
      id,
      UsersController.actorOf(actor, ip),
    );
  }

  /// L'acteur d'une action sensible : QUI, depuis OÙ (spec §24).
  private static actorOf(user: AuthenticatedUser, ip?: string): ActorContext {
    return { userId: user.id, ipAddress: ip };
  }
}
