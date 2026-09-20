import { Body, Controller, Get, Ip, Param, Post, Query } from '@nestjs/common';
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
  CreateReceptionDto,
  ReceptionDto,
  ReceptionListDto,
  ReceptionListQueryDto,
} from './dto/reception.dto';
import { ReceptionsService } from './receptions.service';

@ApiTags('Réceptions')
@ApiBearerAuth()
@Controller('receptions')
export class ReceptionsController {
  constructor(private readonly receptions: ReceptionsService) {}

  @Roles(RoleCode.ADMIN, RoleCode.MAGASINIER)
  @RequirePermissions(PERMISSIONS.RECEPTION_CREATE)
  @Post()
  @ApiOperation({
    summary: 'Enregistre une réception (partielle possible)',
    description:
      'Le stock augmente UNIQUEMENT des quantités réellement reçues, et la dette ' +
      'fournisseur du TTC figé ici. Une commande peut avoir plusieurs réceptions ; ' +
      'son statut suit le cumul (PARTIELLEMENT_RECUE puis RECUE). Surlivraison ' +
      'refusée. Renvoi de la même `clientMutationId` → même bon, sans second effet.',
  })
  @ApiCreatedResponse({ type: ReceptionDto })
  @ApiConflictResponse({ type: ErrorResponseDto })
  create(
    @Body() dto: CreateReceptionDto,
    @CurrentUser() user: AuthenticatedUser,
    @Ip() ip: string,
  ): Promise<ReceptionDto> {
    return this.receptions.create(dto, user, {
      userId: user.id,
      ipAddress: ip,
    });
  }

  // Lectures gardées par `reception.create` : `docs/permissions.md` n'accorde
  // « Réceptionner » qu'à l'admin et au magasinier et ne prévoit PAS de droit de
  // lecture distinct. En inventer un ici dépasserait la matrice validée.
  @Roles(RoleCode.ADMIN, RoleCode.MAGASINIER)
  @RequirePermissions(PERMISSIONS.RECEPTION_CREATE)
  @Get()
  @ApiOperation({ summary: 'Réceptions (filtres fournisseur, commande)' })
  @ApiOkResponse({ type: ReceptionListDto })
  findAll(@Query() query: ReceptionListQueryDto): Promise<ReceptionListDto> {
    return this.receptions.findAll(query);
  }

  @Roles(RoleCode.ADMIN, RoleCode.MAGASINIER)
  @RequirePermissions(PERMISSIONS.RECEPTION_CREATE)
  @Get(':id')
  @ApiOperation({ summary: 'Détail d’un bon de réception' })
  @ApiOkResponse({ type: ReceptionDto })
  findOne(@Param('id', CanonicalUuidPipe) id: string): Promise<ReceptionDto> {
    return this.receptions.findOne(id);
  }
}
