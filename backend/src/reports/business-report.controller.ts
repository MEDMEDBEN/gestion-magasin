import { Controller, Get, Query, StreamableFile } from '@nestjs/common';
import { Throttle } from '@nestjs/throttler';
import {
  ApiBearerAuth,
  ApiOkResponse,
  ApiOperation,
  ApiProduces,
  ApiTags,
} from '@nestjs/swagger';
import { RequireFreshAccess, RoleCode, Roles } from '../common/auth.decorators';
import { localDate } from '../common/document-number';
import {
  EXPORT_TYPES,
  ExportFormatQueryDto,
  exportResponse,
  renderExport,
} from '../common/export/export';
import {
  purchasesReportDocument,
  salesReportDocument,
  stockReportDocument,
} from './business-report.export';
import { BusinessReportService } from './business-report.service';
import {
  PurchasesReportDto,
  ReportExportQueryDto,
  ReportPeriodQueryDto,
  SalesReportDto,
  StockReportDto,
} from './dto/business-report.dto';

/// Rapports ventes / stock / achats (spec §21).
///
/// **ADMIN seul**, et c'est un choix : la spec ne liste « rapports » que dans les
/// accès de l'admin (`docs/spec-fonctionnelle.md` §2), et ces rapports portent
/// le chiffre d'affaires et la MARGE — exactement ce que le tableau de bord
/// refuse déjà à un vendeur (il ne lui montre que SES ventes) et au magasinier
/// (aucun CA). La valeur du stock au coût, elle, n'est PAS un secret : les trois
/// rôles lisent coût et quantités (voir `docs/permissions.md`, n°21).
///
/// À ne PAS confondre avec les rapports produits (n°20), ouverts aux trois rôles :
/// ceux-là ne rendent que des listes et des quantités. Si MEDMEDBEN veut ouvrir
/// le rapport de STOCK au magasinier, c'est une ligne — mais il faudra alors
/// décider ce qu'on fait de la valeur au coût qu'il contient.
@ApiTags('Rapports')
@ApiBearerAuth()
@Controller('reports')
export class BusinessReportController {
  constructor(private readonly reports: BusinessReportService) {}

  /// Lecture SENSIBLE (`@RequireFreshAccess`) : CA, marge et valeur de stock. Un
  /// admin rétrogradé cesse de les lire à la seconde, sans attendre les 15 min de
  /// son access token.
  @Roles(RoleCode.ADMIN)
  @RequireFreshAccess()
  @Throttle({ default: { ttl: 60_000, limit: 30 } })
  @Get('sales')
  @ApiOperation({
    summary: 'Ventes sur une période : CA, TVA, remises, marge, tendance',
    description:
      'Ventes VALIDÉES uniquement. `from`/`to` en AAAA-MM-JJ, **`to` inclus** ; ' +
      'par défaut les 30 derniers jours, 730 jours au plus. La marge utilise le ' +
      'DERNIER prix d’achat (règle 5) : elle vaut `null` si aucun produit vendu ' +
      'n’a de coût connu, plutôt qu’un chiffre flatteur. Montants en centimes.',
  })
  @ApiOkResponse({ type: SalesReportDto })
  sales(@Query() query: ReportPeriodQueryDto): Promise<SalesReportDto> {
    return this.reports.sales(query);
  }

  @Roles(RoleCode.ADMIN)
  @RequireFreshAccess()
  @Throttle({ default: { ttl: 60_000, limit: 30 } })
  @Get('stock')
  @ApiOperation({
    summary: 'Stock : valeur au coût, par emplacement, alertes',
    description:
      'SANS période : le stock est un état, pas un flux. Magasin et dépôt ; le ' +
      'transit est exclu. Les produits sans coût connu sont comptés à part au ' +
      'lieu d’être valorisés à zéro. Montants en centimes.',
  })
  @ApiOkResponse({ type: StockReportDto })
  stock(): Promise<StockReportDto> {
    return this.reports.stock();
  }

  @Roles(RoleCode.ADMIN)
  @RequireFreshAccess()
  @Throttle({ default: { ttl: 60_000, limit: 30 } })
  @Get('purchases')
  @ApiOperation({
    summary: 'Achats sur une période : commandé, reçu, par fournisseur',
    description:
      'Brouillons et commandes annulées exclus. Commandé et reçu sont comptés ' +
      'SÉPARÉMENT et ne s’équilibrent pas : une commande de septembre peut être ' +
      'reçue en octobre. Montants en centimes.',
  })
  @ApiOkResponse({ type: PurchasesReportDto })
  purchases(@Query() query: ReportPeriodQueryDto): Promise<PurchasesReportDto> {
    return this.reports.purchases(query);
  }

  // ── Exports (spec §8quinquies) ─────────────────────────────────────────
  // Les MÊMES gardes que la lecture, décorateur pour décorateur : un fichier
  // n'est pas un contournement de permission. Bridés plus serré — un rendu de
  // fichier coûte plus qu'une réponse JSON.

  @Roles(RoleCode.ADMIN)
  @RequireFreshAccess()
  @Throttle({ default: { ttl: 60_000, limit: 10 } })
  @Get('sales/export')
  @ApiOperation({ summary: 'Rapport des ventes en Excel, CSV ou PDF' })
  @ApiProduces(...EXPORT_TYPES)
  @ApiOkResponse({ schema: { type: 'string', format: 'binary' } })
  async salesExport(
    @Query() query: ReportExportQueryDto,
  ): Promise<StreamableFile> {
    const report = await this.reports.sales(query);
    return exportResponse(
      await renderExport(salesReportDocument(report), query.format),
    );
  }

  @Roles(RoleCode.ADMIN)
  @RequireFreshAccess()
  @Throttle({ default: { ttl: 60_000, limit: 10 } })
  @Get('stock/export')
  @ApiOperation({ summary: 'Rapport de stock en Excel, CSV ou PDF' })
  @ApiProduces(...EXPORT_TYPES)
  @ApiOkResponse({ schema: { type: 'string', format: 'binary' } })
  async stockExport(
    @Query() query: ExportFormatQueryDto,
  ): Promise<StreamableFile> {
    const report = await this.reports.stock();
    return exportResponse(
      await renderExport(
        stockReportDocument(report, localDate(new Date())),
        query.format,
      ),
    );
  }

  @Roles(RoleCode.ADMIN)
  @RequireFreshAccess()
  @Throttle({ default: { ttl: 60_000, limit: 10 } })
  @Get('purchases/export')
  @ApiOperation({ summary: 'Rapport des achats en Excel, CSV ou PDF' })
  @ApiProduces(...EXPORT_TYPES)
  @ApiOkResponse({ schema: { type: 'string', format: 'binary' } })
  async purchasesExport(
    @Query() query: ReportExportQueryDto,
  ): Promise<StreamableFile> {
    const report = await this.reports.purchases(query);
    return exportResponse(
      await renderExport(purchasesReportDocument(report), query.format),
    );
  }
}
