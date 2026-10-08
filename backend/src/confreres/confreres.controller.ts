import { Body, Controller, Get, Ip, Param, Post } from '@nestjs/common';
import {
  ApiBearerAuth,
  ApiCreatedResponse,
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
import { CanonicalUuidPipe } from '../common/canonical-uuid.pipe';
import { PERMISSIONS } from '../common/permissions';
import {
  ConfrereDealDto,
  ConfrereDto,
  CreateConfrereDealDto,
  CreateConfrereDto,
} from './confreres.dto';
import { ConfreresService } from './confreres.service';

/// Confrères : admin + vendeur (décision MEDMEDBEN 2026-10-08), depuis
/// l'écran Vente. Le magasinier n'y a pas accès.
@ApiTags('Confrères')
@ApiBearerAuth()
@Controller('confreres')
export class ConfreresController {
  constructor(private readonly confreres: ConfreresService) {}

  @Roles(RoleCode.ADMIN, RoleCode.VENDEUR)
  @RequirePermissions(PERMISSIONS.CUSTOMER_READ)
  @Get()
  @ApiOperation({ summary: 'Confrères et soldes (il me doit / je lui dois)' })
  @ApiOkResponse({ type: [ConfrereDto] })
  findAll(): Promise<ConfrereDto[]> {
    return this.confreres.findAll();
  }

  @Roles(RoleCode.ADMIN, RoleCode.VENDEUR)
  @RequirePermissions(PERMISSIONS.CUSTOMER_WRITE)
  @Post()
  @ApiOperation({ summary: 'Nouveau confrère (fiche client + fournisseur)' })
  @ApiCreatedResponse({ type: ConfrereDto })
  create(
    @Body() dto: CreateConfrereDto,
    @CurrentUser() user: AuthenticatedUser,
    @Ip() ip: string,
  ): Promise<ConfrereDto> {
    return this.confreres.create(dto, { userId: user.id, ipAddress: ip });
  }

  @Roles(RoleCode.ADMIN, RoleCode.VENDEUR)
  @RequirePermissions(PERMISSIONS.SALE_CREATE)
  @Post(':id/deals')
  @ApiOperation({
    summary: 'Achat à un confrère, ou échange (achat + vente) — tout ou rien',
  })
  @ApiCreatedResponse({ type: ConfrereDealDto })
  deal(
    @Param('id', CanonicalUuidPipe) id: string,
    @Body() dto: CreateConfrereDealDto,
    @CurrentUser() user: AuthenticatedUser,
    @Ip() ip: string,
  ): Promise<ConfrereDealDto> {
    return this.confreres.deal(id, dto, user, {
      userId: user.id,
      ipAddress: ip,
    });
  }
}
