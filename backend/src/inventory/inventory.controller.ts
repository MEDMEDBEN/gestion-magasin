import {
  Body,
  Controller,
  Get,
  HttpCode,
  HttpStatus,
  Ip,
  Param,
  Post,
  Query,
} from '@nestjs/common';
import {
  ApiBearerAuth,
  ApiConflictResponse,
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
import { ErrorResponseDto } from '../common/dto/error-response.dto';
import { PERMISSIONS } from '../common/permissions';
import {
  CreateInventoryDto,
  InventoryDto,
  InventoryListDto,
  InventoryListQueryDto,
  SubmitCountDto,
} from './dto/inventory.dto';
import { InventoryService } from './inventory.service';

@ApiTags('Inventaire')
@ApiBearerAuth()
@Controller('inventories')
export class InventoryController {
  constructor(private readonly inventories: InventoryService) {}

  @Roles(RoleCode.ADMIN, RoleCode.MAGASINIER)
  @RequirePermissions(PERMISSIONS.INVENTORY_CREATE)
  @Post()
  @ApiOperation({
    summary: 'Lance un inventaire (complet ou tournant)',
    description:
      'Crée la feuille de comptage avec le stock du moment. AUCUN mouvement de ' +
      'stock. Un COMPLET prend tout ce que le lieu porte, un TOURNANT la liste ' +
      '`productIds` annoncée. Le théorique de chaque ligne est RELU au comptage.',
  })
  @ApiCreatedResponse({ type: InventoryDto })
  @ApiConflictResponse({ type: ErrorResponseDto })
  create(
    @Body() dto: CreateInventoryDto,
    @CurrentUser() user: AuthenticatedUser,
    @Ip() ip: string,
  ): Promise<InventoryDto> {
    return this.inventories.create(dto, user, {
      userId: user.id,
      ipAddress: ip,
    });
  }

  @Roles(RoleCode.ADMIN, RoleCode.MAGASINIER)
  @RequirePermissions(PERMISSIONS.INVENTORY_CREATE)
  @Get()
  @ApiOperation({
    summary: 'Liste paginée des inventaires (filtres statut, à valider)',
  })
  @ApiOkResponse({ type: InventoryListDto })
  findAll(@Query() query: InventoryListQueryDto): Promise<InventoryListDto> {
    return this.inventories.findAll(query);
  }

  @Roles(RoleCode.ADMIN, RoleCode.MAGASINIER)
  @RequirePermissions(PERMISSIONS.INVENTORY_CREATE)
  @Get(':id')
  @ApiOperation({ summary: 'Détail d’un inventaire et de ses écarts' })
  @ApiOkResponse({ type: InventoryDto })
  findOne(@Param('id', CanonicalUuidPipe) id: string): Promise<InventoryDto> {
    return this.inventories.findOne(id);
  }

  @Roles(RoleCode.ADMIN, RoleCode.MAGASINIER)
  @RequirePermissions(PERMISSIONS.INVENTORY_CREATE)
  @Post(':id/count')
  @HttpCode(HttpStatus.OK)
  @ApiOperation({
    summary: 'Saisit le comptage physique',
    description:
      'Calcule l’écart par ligne (compté − théorique relu à cet instant). ' +
      'AUCUN mouvement de stock à cette étape. `done: false` garde le comptage ' +
      'ouvert pour une reprise ; `done: true` le clôt et ouvre la validation, ' +
      'et exige alors que TOUTES les lignes soient comptées.',
  })
  @ApiOkResponse({ type: InventoryDto })
  @ApiConflictResponse({ type: ErrorResponseDto })
  submitCount(
    @Param('id', CanonicalUuidPipe) id: string,
    @Body() dto: SubmitCountDto,
    @CurrentUser() user: AuthenticatedUser,
    @Ip() ip: string,
  ): Promise<InventoryDto> {
    return this.inventories.submitCount(id, dto, user, {
      userId: user.id,
      ipAddress: ip,
    });
  }

  @Roles(RoleCode.ADMIN)
  @RequirePermissions(PERMISSIONS.INVENTORY_VALIDATE)
  @Post(':id/validate')
  @HttpCode(HttpStatus.OK)
  @ApiOperation({
    summary: 'Valide les ajustements (ADMIN SEUL)',
    description:
      'Seule étape qui touche le stock : un mouvement AJUSTEMENT_INVENTAIRE ' +
      'par écart, en DELTA. Une vente survenue depuis le comptage ne gêne pas — ' +
      'le delta s’y ajoute au lieu de l’écraser. Seule la double correction du ' +
      'même écart par un AUTRE inventaire est refusée (`INVENTORY_STALE_COUNT`).',
  })
  @ApiOkResponse({ type: InventoryDto })
  @ApiConflictResponse({ type: ErrorResponseDto })
  validate(
    @Param('id', CanonicalUuidPipe) id: string,
    @CurrentUser() user: AuthenticatedUser,
    @Ip() ip: string,
  ): Promise<InventoryDto> {
    return this.inventories.validate(id, user, {
      userId: user.id,
      ipAddress: ip,
    });
  }
}
