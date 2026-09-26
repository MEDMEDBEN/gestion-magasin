import { Controller, Get, Query } from '@nestjs/common';
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
  RequirePermissions,
  RoleCode,
  Roles,
} from '../common/auth.decorators';
import { PERMISSIONS } from '../common/permissions';
import {
  DemandQueryDto,
  DormantProductListDto,
  DormantQueryDto,
  ProductDemandDto,
} from './dto/product-report.dto';
import { ProductReportService } from './product-report.service';

/// Produits dormants et produits demandés (spec §20).
///
/// Ouvert aux TROIS rôles, comme le tableau de bord : ce sont des listes de
/// produits, et chaque rôle en fait quelque chose. L'admin décide des achats, le
/// magasinier des transferts, le vendeur pousse ce qui dort (« promotion », dit
/// la spec). Le coût d'achat est visible des trois rôles depuis la décision du
/// 2026-09-22 — c'est lui qui donne la valeur du stock qui dort.
///
/// Rien n'est fermé au vendeur ici, contrairement au réapprovisionnement (n°19) :
/// cette liste ne porte NI fournisseur NI chemin vers une commande. Si MEDMEDBEN
/// veut la fermer, il faudra une permission dédiée (`report.read`), qui n'existe
/// pas encore volontairement — un droit que les trois rôles portent est un droit
/// mort.
@ApiTags('Rapports produits')
@ApiBearerAuth()
@Controller('reports')
export class ProductReportController {
  constructor(private readonly reports: ProductReportService) {}

  /// Lecture SENSIBLE (`@RequireFreshAccess`) : elle expose des coûts d'achat et
  /// l'état du stock, donc les droits sont relus en base et non pris dans le
  /// token — un compte désactivé cesse aussitôt de lire.
  ///
  /// Débit bridé : la réponse parcourt tout le catalogue actif et agrège
  /// l'historique des mouvements.
  /// Les permissions sont cumulatives (ET) : ce rapport rend une VALEUR DE STOCK
  /// AU COÛT, donc il exige `cost.read` comme la fiche produit, et les deux
  /// droits de lecture de stock comme le tableau de bord — le chiffre couvre le
  /// magasin ET le dépôt. Les trois rôles les ont aujourd'hui ; ces permissions
  /// existent pour pouvoir être RETIRÉES, et ce rapport ne doit pas devenir le
  /// contournement du jour où elles le seront (audit sécurité).
  @Roles(RoleCode.ADMIN, RoleCode.VENDEUR, RoleCode.MAGASINIER)
  @RequirePermissions(
    PERMISSIONS.PRODUCT_READ,
    PERMISSIONS.COST_READ,
    PERMISSIONS.STOCK_READ_STORE,
    PERMISSIONS.STOCK_READ_WAREHOUSE,
  )
  @RequireFreshAccess()
  @Throttle({ default: { ttl: 60_000, limit: 30 } })
  @Get('dormant-products')
  @ApiOperation({
    summary: 'Produits qui ne se vendent plus, et l’argent qui y dort',
    description:
      '`days` (7 à 730, défaut 120) : depuis combien de temps sans VENTE. ' +
      'Une réception ne remet PAS l’horloge à zéro — racheter un produit qui ' +
      'ne part pas est justement le problème cherché. Seuls les produits qui ' +
      'ont du stock sont rendus : un dormant sans stock ne coûte rien. ' +
      'Classés par valeur immobilisée décroissante. Montants en centimes.',
  })
  @ApiOkResponse({ type: DormantProductListDto })
  dormant(@Query() query: DormantQueryDto): Promise<DormantProductListDto> {
    return this.reports.dormant(query);
  }

  @Roles(RoleCode.ADMIN, RoleCode.VENDEUR, RoleCode.MAGASINIER)
  @RequirePermissions(PERMISSIONS.PRODUCT_READ)
  @RequireFreshAccess()
  @Throttle({ default: { ttl: 60_000, limit: 30 } })
  @Get('product-demand')
  @ApiOperation({
    summary: 'Les plus vendus, les plus demandés au dépôt, et les non servis',
    description:
      '`days` (7 à 730, défaut 30). Trois classements de 10 lignes. Le ' +
      'troisième est la demande que le dépôt n’a PAS pu servir : l’écart ' +
      'entre demandé et préparé, sur les transferts réellement préparés. ' +
      'Le chiffre d’affaires par produit n’est rendu qu’à l’ADMIN (`null` ' +
      'sinon) : le tableau de bord ne montre à un vendeur que SES ventes, et ' +
      'ce rapport ne doit pas contourner ce cloisonnement.',
  })
  @ApiOkResponse({ type: ProductDemandDto })
  demand(
    @Query() query: DemandQueryDto,
    @CurrentUser() user: AuthenticatedUser,
  ): Promise<ProductDemandDto> {
    return this.reports.demand(query, user);
  }
}
