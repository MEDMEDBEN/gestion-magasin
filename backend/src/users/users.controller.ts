import {
  Body,
  Controller,
  Get,
  Ip,
  Param,
  ParseUUIDPipe,
  Patch,
  Post,
  Query,
} from '@nestjs/common';
import {
  ApiBearerAuth,
  ApiForbiddenResponse,
  ApiOkResponse,
  ApiOperation,
  ApiTags,
} from '@nestjs/swagger';
import {
  AuthenticatedUser,
  CurrentUser,
  RequirePermissions,
  RoleCode,
  Roles,
} from '../common/auth.decorators';
import { ErrorResponseDto } from '../common/dto/error-response.dto';
import { PaginationQueryDto } from '../common/dto/pagination.dto';
import { PERMISSIONS } from '../common/permissions';
import {
  CreateUserDto,
  ResetPasswordDto,
  UpdateUserDto,
  UserDto,
  UserListDto,
} from './dto/user.dto';
import { ActorContext, UsersService } from './users.service';

/// Toute la gestion des comptes est réservée à l'ADMIN (docs/permissions.md § Administration).
@ApiTags('Utilisateurs')
@ApiBearerAuth()
@ApiForbiddenResponse({ type: ErrorResponseDto })
@Roles(RoleCode.ADMIN)
@RequirePermissions(PERMISSIONS.USER_MANAGE)
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
  @ApiOkResponse({ type: UserDto })
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

  @Get(':id')
  @ApiOperation({ summary: 'Détail d’un utilisateur' })
  @ApiOkResponse({ type: UserDto })
  findOne(@Param('id', ParseUUIDPipe) id: string): Promise<UserDto> {
    return this.usersService.findOne(id);
  }

  @Patch(':id')
  @ApiOperation({
    summary: 'Modifie un utilisateur (rôles, permissions, activation)',
    description: 'Désactiver un compte révoque immédiatement toutes ses sessions.',
  })
  @ApiOkResponse({ type: UserDto })
  update(
    @Param('id', ParseUUIDPipe) id: string,
    @Body() dto: UpdateUserDto,
    @CurrentUser() actor: AuthenticatedUser,
    @Ip() ip: string,
  ): Promise<UserDto> {
    return this.usersService.update(id, dto, UsersController.actorOf(actor, ip));
  }

  @Post(':id/reset-password')
  @ApiOperation({
    summary: 'Réinitialise le mot de passe',
    description: 'Repose un mot de passe temporaire et coupe toutes les sessions.',
  })
  @ApiOkResponse({ type: UserDto })
  resetPassword(
    @Param('id', ParseUUIDPipe) id: string,
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
  @ApiOperation({ summary: 'Révoque toutes les sessions (téléphone volé, départ)' })
  revokeSessions(
    @Param('id', ParseUUIDPipe) id: string,
    @CurrentUser() actor: AuthenticatedUser,
    @Ip() ip: string,
  ): Promise<{ revoked: number }> {
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
