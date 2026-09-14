import { Body, Controller, Get, Param, Patch, Post } from '@nestjs/common';
import {
  ApiBearerAuth,
  ApiConflictResponse,
  ApiCreatedResponse,
  ApiOkResponse,
  ApiOperation,
  ApiTags,
} from '@nestjs/swagger';
import { RequirePermissions, RoleCode, Roles } from '../common/auth.decorators';
import { CanonicalUuidPipe } from '../common/canonical-uuid.pipe';
import { ErrorResponseDto } from '../common/dto/error-response.dto';
import { PERMISSIONS } from '../common/permissions';
import {
  CreateLocationDto,
  LocationDto,
  UpdateLocationDto,
} from './dto/location.dto';
import { LocationsService } from './locations.service';

const ALL_ROLES = [RoleCode.ADMIN, RoleCode.VENDEUR, RoleCode.MAGASINIER];

@ApiTags('Emplacements')
@ApiBearerAuth()
@Controller('locations')
export class LocationsController {
  constructor(private readonly locationsService: LocationsService) {}

  @Roles(...ALL_ROLES)
  @RequirePermissions(PERMISSIONS.PRODUCT_READ)
  @Get()
  @ApiOperation({
    summary: 'Liste des emplacements (inactifs compris)',
    description:
      'MAGASIN / DEPOT / TRANSIT portent le stock ; EMPLACEMENT = position physique au dépôt.',
  })
  @ApiOkResponse({ type: [LocationDto] })
  findAll(): Promise<LocationDto[]> {
    return this.locationsService.findAll();
  }

  @Roles(RoleCode.ADMIN, RoleCode.MAGASINIER)
  @RequirePermissions(PERMISSIONS.LOCATION_MANAGE)
  @Post()
  @ApiOperation({ summary: 'Crée un emplacement de dépôt' })
  @ApiCreatedResponse({ type: LocationDto })
  @ApiConflictResponse({
    type: ErrorResponseDto,
    description: 'Code déjà utilisé',
  })
  create(@Body() dto: CreateLocationDto): Promise<LocationDto> {
    return this.locationsService.create(dto);
  }

  @Roles(RoleCode.ADMIN, RoleCode.MAGASINIER)
  @RequirePermissions(PERMISSIONS.LOCATION_MANAGE)
  @Patch(':id')
  @ApiOperation({ summary: 'Modifie ou désactive un emplacement de dépôt' })
  @ApiOkResponse({ type: LocationDto })
  update(
    @Param('id', CanonicalUuidPipe) id: string,
    @Body() dto: UpdateLocationDto,
  ): Promise<LocationDto> {
    return this.locationsService.update(id, dto);
  }
}
