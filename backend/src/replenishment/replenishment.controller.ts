import { Controller, Get, Query } from '@nestjs/common';
import { Throttle } from '@nestjs/throttler';
import {
  ApiBearerAuth,
  ApiOkResponse,
  ApiOperation,
  ApiTags,
} from '@nestjs/swagger';
import {
  RequireFreshAccess,
  RequirePermissions,
  RoleCode,
  Roles,
} from '../common/auth.decorators';
import { PERMISSIONS } from '../common/permissions';
import {
  ReplenishmentQueryDto,
  ReplenishmentListDto,
} from './dto/replenishment.dto';
import { ReplenishmentService } from './replenishment.service';

/// Réapprovisionnement (spec §19).
///
/// Réservé à ceux qui peuvent COMMANDER (`purchase.create` : admin et
/// magasinier). Le vendeur n'a ni ce droit ni l'accès aux fournisseurs — lui
/// montrer une liste d'achats à faire serait lui montrer une porte fermée, et la
/// liste porte les derniers prix d'achat et le fournisseur principal.
///
/// Cet écran ne commande RIEN par lui-même : il propose, l'utilisateur ajuste,
/// puis passe par la commande fournisseur existante. La préparation
/// automatique de la commande est explicitement remise à P2 (n°22).
@ApiTags('Réapprovisionnement')
@ApiBearerAuth()
@Controller('replenishment')
export class ReplenishmentController {
  constructor(private readonly replenishment: ReplenishmentService) {}

  /// Lecture SENSIBLE (`@RequireFreshAccess`) : les droits sont relus en base et
  /// non pris dans le token, comme pour le tableau de bord. Sans cela un compte
  /// rétrogradé continuerait de lire coûts d'achat et fournisseurs pendant les
  /// 15 minutes de vie de son access token.
  ///
  /// Débit bridé : la réponse parcourt tout le catalogue actif ; la limite
  /// globale (120/min PAR IP, tout le magasin derrière la même) laisserait un
  /// seul compte les enchaîner.
  @Roles(RoleCode.ADMIN, RoleCode.MAGASINIER)
  @RequirePermissions(PERMISSIONS.PURCHASE_CREATE)
  @RequireFreshAccess()
  @Throttle({ default: { ttl: 60_000, limit: 30 } })
  @Get()
  @ApiOperation({
    summary: 'Produits à racheter, du plus urgent au moins urgent',
    description:
      'Règle : `stock <= seuil minimum` (spec §19), stock compté en MAGASIN + ' +
      'DÉPÔT, transit exclu. Une rupture remonte même sans seuil défini. La ' +
      'quantité proposée est à modifier avant de commander. Montants en centimes.',
  })
  @ApiOkResponse({ type: ReplenishmentListDto })
  findAll(
    @Query() query: ReplenishmentQueryDto,
  ): Promise<ReplenishmentListDto> {
    return this.replenishment.findAll(query);
  }
}
