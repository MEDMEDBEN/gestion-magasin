import {
  Body,
  Controller,
  Get,
  Ip,
  Param,
  Patch,
  Post,
  Query,
} from '@nestjs/common';
import {
  ApiBearerAuth,
  ApiBody,
  ApiConflictResponse,
  ApiCreatedResponse,
  ApiOkResponse,
  ApiOperation,
  ApiParam,
  ApiTags,
} from '@nestjs/swagger';
import { ActorContext } from '../audit/audit-writer';
import {
  AuthenticatedUser,
  CurrentUser,
  RequirePermissions,
  RoleCode,
  Roles,
} from '../common/auth.decorators';
import { CanonicalUuidPipe } from '../common/canonical-uuid.pipe';
import { ErrorResponseDto } from '../common/dto/error-response.dto';
import { notImplemented } from '../common/not-implemented';
import { PERMISSIONS } from '../common/permissions';
import { CatalogService } from './catalog.service';
import { CatalogChangesDto, CatalogChangesQueryDto } from './dto/catalog.dto';
import {
  CategoryDto,
  CreateCategoryDto,
  CreateProductDto,
  PriceTierDto,
  ProductDto,
  ProductListDto,
  ProductListQueryDto,
  ProductPriceDto,
  SetProductPriceDto,
  TaxRateDto,
  UpdateCategoryDto,
  UpdateProductDto,
} from './dto/product.dto';
import { ProductsService } from './products.service';

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
  findAll(@Query() query: ProductListQueryDto): Promise<ProductListDto> {
    return this.productsService.findAll(query);
  }

  @Roles(...ALL_ROLES)
  @RequirePermissions(PERMISSIONS.PRODUCT_READ)
  @Get('barcode/:barcode')
  @ApiOperation({ summary: 'Recherche par code-barres (scan, douchette)' })
  @ApiOkResponse({ type: ProductDto })
  findByBarcode(@Param('barcode') barcode: string): Promise<ProductDto> {
    return this.productsService.findByBarcode(barcode);
  }

  @Roles(...ALL_ROLES)
  @RequirePermissions(PERMISSIONS.PRODUCT_READ)
  @Get(':id')
  @ApiOperation({ summary: 'Détail d’un produit' })
  @ApiOkResponse({ type: ProductDto })
  findOne(@Param('id', CanonicalUuidPipe) id: string): Promise<ProductDto> {
    return this.productsService.findOne(id);
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
  create(
    @Body() dto: CreateProductDto,
    @CurrentUser() user: AuthenticatedUser,
    @Ip() ip: string,
  ): Promise<ProductDto> {
    return this.productsService.create(dto, actorOf(user, ip));
  }

  @Roles(RoleCode.ADMIN)
  @RequirePermissions(PERMISSIONS.PRODUCT_WRITE)
  @Patch(':id')
  @ApiOperation({
    summary: 'Modifie un produit (admin uniquement)',
    description: 'Changer `isActive` exige en plus `product.disable`.',
  })
  @ApiOkResponse({ type: ProductDto })
  update(
    @Param('id', CanonicalUuidPipe) id: string,
    @Body() dto: UpdateProductDto,
    @CurrentUser() user: AuthenticatedUser,
    @Ip() ip: string,
  ): Promise<ProductDto> {
    return this.productsService.update(id, dto, user, actorOf(user, ip));
  }

  @Roles(RoleCode.ADMIN)
  @RequirePermissions(PERMISSIONS.PRICE_MANAGE)
  @Post(':id/prices')
  @ApiOperation({
    summary: 'Fixe le prix d’un produit pour un tarif (admin uniquement)',
    description:
      'Prix HT en centimes. Le vendeur applique, il ne fixe jamais un prix.',
  })
  @ApiOkResponse({ type: ProductPriceDto })
  @ApiParam({ name: 'id', format: 'uuid' })
  @ApiBody({ type: SetProductPriceDto })
  setPrice(): Promise<ProductPriceDto> {
    return notImplemented('Ventes / tarifs');
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
  constructor(private readonly catalogService: CatalogService) {}

  @Roles(...ALL_ROLES)
  @RequirePermissions(PERMISSIONS.PRICE_READ)
  @Get('tiers')
  @ApiOperation({ summary: 'Tarifs actifs (DETAIL, GROS…)' })
  @ApiOkResponse({ type: [PriceTierDto] })
  tiers(): Promise<PriceTierDto[]> {
    return this.catalogService.priceTiers();
  }

  @Roles(...ALL_ROLES)
  @RequirePermissions(PERMISSIONS.PRICE_READ)
  @Get('tax-rates')
  @ApiOperation({ summary: 'Taux de TVA actifs' })
  @ApiOkResponse({ type: [TaxRateDto] })
  taxRates(): Promise<TaxRateDto[]> {
    return this.catalogService.taxRates();
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
  changes(@Query() query: CatalogChangesQueryDto): Promise<CatalogChangesDto> {
    return this.catalogService.changes(query);
  }
}
