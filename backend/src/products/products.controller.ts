import { Body, Controller, Get, Param, ParseUUIDPipe, Patch, Post, Query } from '@nestjs/common';
import {
  ApiBearerAuth,
  ApiOkResponse,
  ApiOperation,
  ApiTags,
} from '@nestjs/swagger';
import { RequirePermissions, RoleCode, Roles } from '../common/auth.decorators';
import { PaginationQueryDto } from '../common/dto/pagination.dto';
import { notImplemented } from '../common/not-implemented';
import { PERMISSIONS } from '../common/permissions';
import {
  CategoryDto,
  CreateCategoryDto,
  CreateProductDto,
  PriceTierDto,
  ProductDto,
  ProductPriceDto,
  SetProductPriceDto,
  TaxRateDto,
  UpdateProductDto,
} from './dto/product.dto';

const ALL_ROLES = [RoleCode.ADMIN, RoleCode.VENDEUR, RoleCode.MAGASINIER];

/// CONTRAT FIGÉ — implémentation avec la feature P0 n°2 « Produits + catégories + emplacements ».
@ApiTags('Produits')
@ApiBearerAuth()
@Controller('products')
export class ProductsController {
  @Roles(...ALL_ROLES)
  @RequirePermissions(PERMISSIONS.PRODUCT_READ)
  @Get()
  @ApiOperation({ summary: 'Liste paginée des produits' })
  @ApiOkResponse({ type: [ProductDto] })
  findAll(@Query() _query: PaginationQueryDto): Promise<ProductDto[]> {
    return notImplemented('Produits');
  }

  @Roles(...ALL_ROLES)
  @RequirePermissions(PERMISSIONS.PRODUCT_READ)
  @Get('barcode/:barcode')
  @ApiOperation({
    summary: 'Recherche par code-barres (scan mobile)',
    description: 'Chemin optimisé pour le scanner : réponse minimale, produit + stock.',
  })
  @ApiOkResponse({ type: ProductDto })
  findByBarcode(@Param('barcode') _barcode: string): Promise<ProductDto> {
    return notImplemented('Produits');
  }

  @Roles(...ALL_ROLES)
  @RequirePermissions(PERMISSIONS.PRODUCT_READ)
  @Get(':id')
  @ApiOperation({ summary: 'Détail d’un produit' })
  @ApiOkResponse({ type: ProductDto })
  findOne(@Param('id', ParseUUIDPipe) _id: string): Promise<ProductDto> {
    return notImplemented('Produits');
  }

  @Roles(RoleCode.ADMIN)
  @RequirePermissions(PERMISSIONS.PRODUCT_WRITE)
  @Post()
  @ApiOperation({
    summary: 'Crée un produit (admin uniquement)',
    description:
      'Sans `barcode`, le serveur génère un code interne garanti unique (règle 15).',
  })
  @ApiOkResponse({ type: ProductDto })
  create(@Body() _dto: CreateProductDto): Promise<ProductDto> {
    return notImplemented('Produits');
  }

  @Roles(RoleCode.ADMIN)
  @RequirePermissions(PERMISSIONS.PRODUCT_WRITE)
  @Patch(':id')
  @ApiOperation({ summary: 'Modifie un produit (admin uniquement)' })
  @ApiOkResponse({ type: ProductDto })
  update(
    @Param('id', ParseUUIDPipe) _id: string,
    @Body() _dto: UpdateProductDto,
  ): Promise<ProductDto> {
    return notImplemented('Produits');
  }

  @Roles(RoleCode.ADMIN)
  @RequirePermissions(PERMISSIONS.PRICE_MANAGE)
  @Post(':id/prices')
  @ApiOperation({
    summary: 'Fixe le prix d’un produit pour un tarif (admin uniquement)',
    description: 'Prix HT en centimes. Le vendeur applique, il ne fixe jamais un prix.',
  })
  @ApiOkResponse({ type: ProductPriceDto })
  setPrice(
    @Param('id', ParseUUIDPipe) _id: string,
    @Body() _dto: SetProductPriceDto,
  ): Promise<ProductPriceDto> {
    return notImplemented('Ventes / tarifs');
  }
}

@ApiTags('Catégories')
@ApiBearerAuth()
@Controller('categories')
export class CategoriesController {
  @Roles(...ALL_ROLES)
  @RequirePermissions(PERMISSIONS.PRODUCT_READ)
  @Get()
  @ApiOperation({ summary: 'Arborescence des catégories' })
  @ApiOkResponse({ type: [CategoryDto] })
  findAll(): Promise<CategoryDto[]> {
    return notImplemented('Produits');
  }

  @Roles(RoleCode.ADMIN)
  @RequirePermissions(PERMISSIONS.PRODUCT_WRITE)
  @Post()
  @ApiOperation({ summary: 'Crée une catégorie (admin uniquement)' })
  @ApiOkResponse({ type: CategoryDto })
  create(@Body() _dto: CreateCategoryDto): Promise<CategoryDto> {
    return notImplemented('Produits');
  }
}

@ApiTags('Tarifs & TVA')
@ApiBearerAuth()
@Controller('pricing')
export class PricingController {
  @Roles(...ALL_ROLES)
  @RequirePermissions(PERMISSIONS.PRICE_READ)
  @Get('tiers')
  @ApiOperation({ summary: 'Tarifs disponibles (DETAIL, GROS…)' })
  @ApiOkResponse({ type: [PriceTierDto] })
  tiers(): Promise<PriceTierDto[]> {
    return notImplemented('Ventes / tarifs');
  }

  @Roles(...ALL_ROLES)
  @RequirePermissions(PERMISSIONS.PRICE_READ)
  @Get('tax-rates')
  @ApiOperation({ summary: 'Taux de TVA' })
  @ApiOkResponse({ type: [TaxRateDto] })
  taxRates(): Promise<TaxRateDto[]> {
    return notImplemented('Ventes / TVA');
  }
}
