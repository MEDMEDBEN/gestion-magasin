import {
  Body,
  Controller,
  Delete,
  HttpCode,
  HttpStatus,
  Get,
  Ip,
  Param,
  Patch,
  Post,
  Query,
  Res,
  StreamableFile,
  UploadedFile,
  UseInterceptors,
} from '@nestjs/common';
import { FileInterceptor } from '@nestjs/platform-express';
import { Throttle } from '@nestjs/throttler';
import type { Response } from 'express';
import {
  ApiBearerAuth,
  ApiBody,
  ApiConflictResponse,
  ApiConsumes,
  ApiNotFoundResponse,
  ApiProduces,
  ApiCreatedResponse,
  ApiOkResponse,
  ApiOperation,
  ApiTags,
} from '@nestjs/swagger';
import { ActorContext } from '../audit/audit-writer';
import {
  AuthenticatedUser,
  CurrentUser,
  RequireFreshAccess,
  RequirePermissions,
  RoleCode,
  Roles,
} from '../common/auth.decorators';
import { CanonicalUuidPipe } from '../common/canonical-uuid.pipe';
import { IMAGE_UPLOAD_LIMITS } from '../common/uploads';
import { ErrorResponseDto } from '../common/dto/error-response.dto';
import { PERMISSIONS } from '../common/permissions';
import { CatalogService } from './catalog.service';
import { CatalogChangesDto, CatalogChangesQueryDto } from './dto/catalog.dto';
import {
  CategoryDto,
  CreateCategoryDto,
  CreateProductDto,
  LabelsDto,
  PriceTierDto,
  ProductDto,
  ProductListDto,
  ProductListQueryDto,
  PriceChangeDto,
  ProspectDto,
  SetProductPriceDto,
  UpdateCategoryDto,
  UpdateProductDto,
} from './dto/product.dto';
import { ProductsService } from './products.service';
import { PricingService } from './pricing.service';
import {
  CreatePriceTierDto,
  ListPricingQueryDto,
  UpdatePriceTierDto,
} from './dto/pricing.dto';

const ALL_ROLES = [RoleCode.ADMIN, RoleCode.VENDEUR, RoleCode.MAGASINIER];

const actorOf = (user: AuthenticatedUser, ip?: string): ActorContext => ({
  userId: user.id,
  ipAddress: ip,
});

@ApiTags('Produits')
@ApiBearerAuth()
@Controller('products')
export class ProductsController {
  constructor(private readonly productsService: ProductsService) {}

  @Roles(...ALL_ROLES)
  @RequirePermissions(PERMISSIONS.PRODUCT_READ)
  @Get()
  @ApiOperation({
    summary: 'Liste paginée des produits',
    description:
      'Recherche `q` sur nom, référence, marque et code-barres. Actifs seulement par défaut.',
  })
  @ApiOkResponse({ type: ProductListDto })
  findAll(
    @Query() query: ProductListQueryDto,
    @CurrentUser() user: AuthenticatedUser,
  ): Promise<ProductListDto> {
    return this.productsService.findAll(query, user);
  }

  /// Étiquettes (spec §8ter). Une lecture, en POST : la liste des produits
  /// dépasserait la longueur d'une URL. Le prix est imprimé : `price.read` en
  /// plus de `product.read` — les trois rôles les ont.
  @Roles(...ALL_ROLES)
  @RequirePermissions(PERMISSIONS.PRODUCT_READ, PERMISSIONS.PRICE_READ)
  // Rendu synchrone (images + PDF) : bridé comme les autres documents.
  @Throttle({ default: { ttl: 60_000, limit: 30 } })
  @Post('labels')
  @HttpCode(HttpStatus.OK)
  @ApiOperation({
    summary: 'Étiquettes à imprimer : nom, prix TTC, code-barres (PDF)',
    description:
      'Planche A4 de 24 (70 × 37 mm) ou rouleau thermique 50 × 30 mm. ' +
      'Produits actifs ; prix du tarif demandé (défaut : tarif par défaut), ' +
      'TTC calculé comme en caisse. 1 000 étiquettes au plus.',
  })
  @ApiProduces('application/pdf')
  @ApiOkResponse({ schema: { type: 'string', format: 'binary' } })
  async labels(@Body() dto: LabelsDto): Promise<StreamableFile> {
    const pdf = await this.productsService.labels(dto);
    return new StreamableFile(pdf, {
      type: 'application/pdf',
      disposition: 'inline; filename="etiquettes.pdf"',
    });
  }

  @Roles(...ALL_ROLES)
  @RequirePermissions(PERMISSIONS.PRODUCT_READ)
  @Get('barcode/:barcode')
  @ApiOperation({ summary: 'Recherche par code-barres (scan, douchette)' })
  @ApiOkResponse({ type: ProductDto })
  findByBarcode(
    @Param('barcode') barcode: string,
    @CurrentUser() user: AuthenticatedUser,
  ): Promise<ProductDto> {
    return this.productsService.findByBarcode(barcode, user);
  }

  @Roles(...ALL_ROLES)
  @RequirePermissions(PERMISSIONS.PRODUCT_READ)
  @Get(':id')
  @ApiOperation({ summary: 'Détail d’un produit' })
  @ApiOkResponse({ type: ProductDto })
  findOne(
    @Param('id', CanonicalUuidPipe) id: string,
    @CurrentUser() user: AuthenticatedUser,
  ): Promise<ProductDto> {
    return this.productsService.findOne(id, user);
  }

  @Roles(RoleCode.ADMIN)
  @RequirePermissions(PERMISSIONS.PRODUCT_WRITE)
  @Post()
  @ApiOperation({
    summary: 'Crée un produit (admin uniquement)',
    description:
      'Sans `barcode`, le serveur génère un EAN-13 interne garanti unique (règle 15).',
  })
  @ApiCreatedResponse({ type: ProductDto })
  @ApiConflictResponse({
    type: ErrorResponseDto,
    description: '`BARCODE_ALREADY_USED` ou référence déjà prise (`CONFLICT`)',
  })
  async create(
    @Body() dto: CreateProductDto,
    @CurrentUser() user: AuthenticatedUser,
    @Ip() ip: string,
  ): Promise<ProductDto> {
    ProductsService.assertCanSetCost(dto, user);
    return ProductsService.forViewer(
      await this.productsService.create(dto, actorOf(user, ip)),
      user,
    );
  }

  @Roles(RoleCode.ADMIN)
  @RequirePermissions(PERMISSIONS.PRODUCT_WRITE)
  @Patch(':id')
  @ApiOperation({
    summary: 'Modifie un produit (admin uniquement)',
    description: 'Changer `isActive` exige en plus `product.disable`.',
  })
  @ApiOkResponse({ type: ProductDto })
  async update(
    @Param('id', CanonicalUuidPipe) id: string,
    @Body() dto: UpdateProductDto,
    @CurrentUser() user: AuthenticatedUser,
    @Ip() ip: string,
  ): Promise<ProductDto> {
    return ProductsService.forViewer(
      await this.productsService.update(id, dto, user, actorOf(user, ip)),
      user,
    );
  }

  @Roles(RoleCode.ADMIN)
  @RequirePermissions(PERMISSIONS.PRODUCT_WRITE)
  @Post(':id/image')
  @UseInterceptors(
    FileInterceptor('image', {
      limits: IMAGE_UPLOAD_LIMITS,
    }),
  )
  @ApiConsumes('multipart/form-data')
  @ApiBody({
    schema: {
      type: 'object',
      properties: { image: { type: 'string', format: 'binary' } },
    },
  })
  @ApiOperation({
    summary: 'Pose ou remplace la photo du produit (admin)',
    description: 'JPEG, PNG ou WebP, 2 Mo max — type vérifié sur le contenu.',
  })
  @ApiOkResponse({ type: ProductDto })
  async setImage(
    @Param('id', CanonicalUuidPipe) id: string,
    @UploadedFile() file: Express.Multer.File | undefined,
    @CurrentUser() user: AuthenticatedUser,
    @Ip() ip: string,
  ): Promise<ProductDto> {
    return ProductsService.forViewer(
      await this.productsService.setImage(id, file, actorOf(user, ip)),
      user,
    );
  }

  @Roles(RoleCode.ADMIN)
  @RequirePermissions(PERMISSIONS.PRODUCT_WRITE)
  @Delete(':id/image')
  @ApiOperation({ summary: 'Retire la photo du produit (admin)' })
  @ApiOkResponse({ type: ProductDto })
  async removeImage(
    @Param('id', CanonicalUuidPipe) id: string,
    @CurrentUser() user: AuthenticatedUser,
    @Ip() ip: string,
  ): Promise<ProductDto> {
    return ProductsService.forViewer(
      await this.productsService.removeImage(id, actorOf(user, ip)),
      user,
    );
  }

  /// Contact clients ciblé (P2 n°23) : ADMIN seul — la liste révèle ce que
  /// chaque client achète (le vendeur ne voit que SES ventes).
  @Roles(RoleCode.ADMIN)
  @RequirePermissions(PERMISSIONS.PRODUCT_READ, PERMISSIONS.CUSTOMER_READ)
  @RequireFreshAccess()
  @Throttle({ default: { ttl: 60_000, limit: 30 } })
  @Get(':id/prospects')
  @ApiOperation({
    summary: 'Clients ayant acheté une catégorie proche, avec leur message',
  })
  @ApiOkResponse({ type: [ProspectDto] })
  prospects(
    @Param('id', CanonicalUuidPipe) id: string,
  ): Promise<ProspectDto[]> {
    return this.productsService.prospects(id);
  }

  /// Mêmes lecteurs que les prix eux-mêmes : les trois rôles avec
  /// `product.read` ET `price.read`.
  @Roles(...ALL_ROLES)
  @RequirePermissions(PERMISSIONS.PRODUCT_READ, PERMISSIONS.PRICE_READ)
  // L'auteur (donnée d'audit) dépend du rôle ADMIN : relu en base.
  @RequireFreshAccess()
  @Get(':id/price-history')
  @ApiOperation({
    summary: 'Historique des prix de vente (changements de tarif)',
  })
  @ApiOkResponse({ type: [PriceChangeDto] })
  priceHistory(
    @Param('id', CanonicalUuidPipe) id: string,
    @CurrentUser() user: AuthenticatedUser,
  ): Promise<PriceChangeDto[]> {
    return this.productsService.priceHistory(id, user);
  }

  @Roles(...ALL_ROLES)
  @RequirePermissions(PERMISSIONS.PRODUCT_READ)
  @Get(':id/image')
  @ApiOperation({
    summary: 'Photo du produit (authentifiée)',
    description:
      'Le stockage est privé : la photo ne sort que par cette route.',
  })
  @ApiProduces('image/jpeg', 'image/png', 'image/webp')
  @ApiNotFoundResponse({ description: 'Le produit n’a pas de photo' })
  async image(
    @Param('id', CanonicalUuidPipe) id: string,
    @Res() res: Response,
  ): Promise<void> {
    const { stream, contentType } = await this.productsService.openImage(id);
    res.setHeader('Content-Type', contentType);
    // Clé versionnée : l'app peut garder la photo en cache sans risque.
    res.setHeader('Cache-Control', 'private, max-age=86400');
    res.setHeader('X-Content-Type-Options', 'nosniff');
    // `pipe` ne transmet PAS l'erreur de la source : un `error` sur le flux de
    // lecture (fichier disparu entre-temps, EIO, volume démonté) sans écouteur
    // devient une `uncaughtException` et tue le processus — aucun filtre Nest
    // ne l'attrape. On coupe la réponse, la requête seule échoue.
    stream.on('error', () => res.destroy());
    stream.pipe(res);
  }

  @Roles(RoleCode.ADMIN)
  @RequirePermissions(PERMISSIONS.PRICE_MANAGE)
  // Route sensible (prix) : accès relu en base (CONVENTIONS.md § Sécurité, audit M5).
  @Post(':id/prices')
  @HttpCode(HttpStatus.OK)
  @ApiOperation({
    summary: 'Fixe le prix d’un produit pour un tarif (admin uniquement)',
    description:
      'Prix HT en centimes. Le vendeur applique, il ne fixe jamais un prix.',
  })
  @ApiOkResponse({ type: ProductDto })
  async setPrice(
    @Param('id', CanonicalUuidPipe) id: string,
    @Body() dto: SetProductPriceDto,
    @CurrentUser() user: AuthenticatedUser,
    @Ip() ip: string,
  ): Promise<ProductDto> {
    return ProductsService.forViewer(
      await this.productsService.setPrice(id, dto, actorOf(user, ip)),
      user,
    );
  }
}

@ApiTags('Catégories')
@ApiBearerAuth()
@Controller('categories')
export class CategoriesController {
  constructor(private readonly catalogService: CatalogService) {}

  @Roles(...ALL_ROLES)
  @RequirePermissions(PERMISSIONS.PRODUCT_READ)
  @Get()
  @ApiOperation({
    summary:
      'Catégories (liste plate, inactives comprises — le client fait l’arbre)',
  })
  @ApiOkResponse({ type: [CategoryDto] })
  findAll(): Promise<CategoryDto[]> {
    return this.catalogService.categories();
  }

  @Roles(RoleCode.ADMIN)
  @RequirePermissions(PERMISSIONS.PRODUCT_WRITE)
  @Post()
  @ApiOperation({
    summary: 'Crée une catégorie ou sous-catégorie (admin uniquement)',
  })
  @ApiCreatedResponse({ type: CategoryDto })
  create(
    @Body() dto: CreateCategoryDto,
    @CurrentUser() user: AuthenticatedUser,
    @Ip() ip: string,
  ): Promise<CategoryDto> {
    return this.catalogService.createCategory(dto, actorOf(user, ip));
  }

  @Roles(RoleCode.ADMIN)
  @RequirePermissions(PERMISSIONS.PRODUCT_WRITE)
  @Patch(':id')
  @ApiOperation({
    summary: 'Renomme, déplace ou désactive une catégorie (admin uniquement)',
  })
  @ApiOkResponse({ type: CategoryDto })
  update(
    @Param('id', CanonicalUuidPipe) id: string,
    @Body() dto: UpdateCategoryDto,
    @CurrentUser() user: AuthenticatedUser,
    @Ip() ip: string,
  ): Promise<CategoryDto> {
    return this.catalogService.updateCategory(id, dto, actorOf(user, ip));
  }
}

@ApiTags('Tarifs & TVA')
@ApiBearerAuth()
@Controller('pricing')
export class PricingController {
  constructor(private readonly pricing: PricingService) {}

  @Roles(...ALL_ROLES)
  @RequirePermissions(PERMISSIONS.PRICE_READ)
  @Get('tiers')
  @ApiOperation({ summary: 'Tarifs (actifs ; tous avec includeInactive)' })
  @ApiOkResponse({ type: [PriceTierDto] })
  tiers(@Query() query: ListPricingQueryDto): Promise<PriceTierDto[]> {
    return this.pricing.priceTiers(query.includeInactive);
  }

  // ── Paramètres (P1 bis n°21h) : ADMIN + price.manage ─────────────────────

  @Roles(RoleCode.ADMIN)
  @RequirePermissions(PERMISSIONS.PRICE_MANAGE)
  @Post('tiers')
  @ApiOperation({ summary: 'Crée un tarif' })
  @ApiCreatedResponse({ type: PriceTierDto })
  createTier(
    @Body() dto: CreatePriceTierDto,
    @CurrentUser() user: AuthenticatedUser,
    @Ip() ip: string,
  ): Promise<PriceTierDto> {
    return this.pricing.createTier(dto, actorOf(user, ip));
  }

  @Roles(RoleCode.ADMIN)
  @RequirePermissions(PERMISSIONS.PRICE_MANAGE)
  @Patch('tiers/:id')
  @ApiOperation({
    summary: 'Renomme, désigne par défaut, (dés)active un tarif',
  })
  @ApiOkResponse({ type: PriceTierDto })
  updateTier(
    @Param('id', CanonicalUuidPipe) id: string,
    @Body() dto: UpdatePriceTierDto,
    @CurrentUser() user: AuthenticatedUser,
    @Ip() ip: string,
  ): Promise<PriceTierDto> {
    return this.pricing.updateTier(id, dto, actorOf(user, ip));
  }
}

@ApiTags('Catalogue (synchronisation)')
@ApiBearerAuth()
@Controller('catalog')
export class CatalogController {
  constructor(private readonly catalogService: CatalogService) {}

  @Roles(...ALL_ROLES)
  @RequirePermissions(PERMISSIONS.PRODUCT_READ)
  @Get('changes')
  @ApiOperation({
    summary: 'Descente delta du catalogue (lecture hors-ligne)',
    description:
      'Sans curseur : tout le catalogue, page par page. Ensuite, seulement ce qui a changé. ' +
      'Inactifs compris. Rappeler tant que `hasMore` est vrai.',
  })
  @ApiOkResponse({ type: CatalogChangesDto })
  changes(
    @Query() query: CatalogChangesQueryDto,
    @CurrentUser() user: AuthenticatedUser,
  ): Promise<CatalogChangesDto> {
    return this.catalogService.changes(query, user);
  }
}
