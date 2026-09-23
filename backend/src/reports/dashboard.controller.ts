import { Controller, Get } from '@nestjs/common';
import { Throttle } from '@nestjs/throttler';
import {
  ApiBearerAuth,
  ApiOkResponse,
  ApiOperation,
  ApiTags,
} from '@nestjs/swagger';
import {
  AuthenticatedUser,
  CurrentUser,
  RequireFreshAccess,
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
  ///
  /// Lecture SENSIBLE (`@RequireFreshAccess`) : les droits sont relus en base,
  /// pas pris dans le token. Sans cela, un admin rétrogradé continuerait de voir
  /// le CA GLOBAL et les dettes du magasin pendant la vie de son access token
  /// (15 min) — c'est le cloisonnement du CA qui en dépend (audit sécurité).
  ///
  /// Débit bridé : un résumé coûte une quinzaine de requêtes dont un parcours
  /// du catalogue ; la limite globale (120/min PAR IP, tout le magasin derrière
  /// la même) laisserait un seul compte les enchaîner.
  @Roles(RoleCode.ADMIN, RoleCode.VENDEUR, RoleCode.MAGASINIER)
  @RequireFreshAccess()
  @Throttle({ default: { ttl: 60_000, limit: 30 } })
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
