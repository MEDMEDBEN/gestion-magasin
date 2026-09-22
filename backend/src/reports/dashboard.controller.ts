import { Controller, Get } from '@nestjs/common';
import {
  ApiBearerAuth,
  ApiOkResponse,
  ApiOperation,
  ApiTags,
} from '@nestjs/swagger';
import {
  AuthenticatedUser,
  CurrentUser,
  RoleCode,
  Roles,
} from '../common/auth.decorators';
import { DashboardService } from './dashboard.service';
import { DashboardDto } from './dto/dashboard.dto';

@ApiTags('Tableau de bord')
@ApiBearerAuth()
@Controller('dashboard')
export class DashboardController {
  constructor(private readonly dashboard: DashboardService) {}

  /// Ouvert aux trois rôles : ce sont les PERMISSIONS du compte qui décident du
  /// contenu, bloc par bloc (un bloc interdit vaut `null`).
  @Roles(RoleCode.ADMIN, RoleCode.VENDEUR, RoleCode.MAGASINIER)
  @Get()
  @ApiOperation({
    summary: 'Résumé d’accueil du compte connecté',
    description:
      'Chaque bloc est présent SEULEMENT si le compte a la permission de ' +
      'l’écran correspondant ; sinon il vaut `null`. Montants en centimes.',
  })
  @ApiOkResponse({ type: DashboardDto })
  summary(@CurrentUser() user: AuthenticatedUser): Promise<DashboardDto> {
    return this.dashboard.summary(user);
  }
}
