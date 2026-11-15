import { HttpStatus, Injectable } from '@nestjs/common';
import { ApiPropertyOptional } from '@nestjs/swagger';
import { Type } from 'class-transformer';
import {
  ArrayMaxSize,
  IsArray,
  IsOptional,
  ValidateNested,
} from 'class-validator';
import { RoleCode } from '../../common/auth.decorators';
import { BusinessException } from '../../common/business.exception';
import { ErrorCode } from '../../common/error-codes';
import { PERMISSIONS, PermissionCode } from '../../common/permissions';
import { validatePayload } from '../../common/validate-payload';
import { AuditAction, OperationType } from '../../generated/prisma/enums';
import {
  CreateProductDto,
  SetProductPriceDto,
} from '../../products/dto/product.dto';
import { PrismaService } from '../../prisma/prisma.service';
import { ProductsService } from '../../products/products.service';
import {
  SyncApplyResult,
  SyncMutationContext,
  SyncMutationHandler,
} from '../sync-mutation.handler';

/// Payload `PRODUCT` : le corps de `POST /products` (id = clé de la mutation)
/// + ses prix par tarif (`POST /products/:id/prices`), en UNE opération — un
/// produit créé hors ligne doit pouvoir se vendre hors ligne (2026-11-15).
export class ProductPayloadDto extends CreateProductDto {
  @ApiPropertyOptional({ type: [SetProductPriceDto] })
  @IsArray()
  @ArrayMaxSize(20)
  @ValidateNested({ each: true })
  @Type(() => SetProductPriceDto)
  @IsOptional()
  prices?: SetProductPriceDto[];
}

/// Produit créé hors ligne. MÊMES règles qu'en ligne (`createInTx`,
/// `setPriceInTx`) : référence et code-barres uniques, code interne attribué
/// SERVEUR s'il manque (règle 15), stock initial par mouvement (règle 2).
@Injectable()
export class ProductHandler implements SyncMutationHandler<ProductPayloadDto> {
  readonly operationType = OperationType.PRODUCT;
  /// Strictement ce qu'exige `POST /api/products` en ligne.
  readonly requiredRoles: readonly RoleCode[] = [
    RoleCode.ADMIN,
    RoleCode.MAGASINIER,
  ];
  readonly requiredPermissions: readonly PermissionCode[] = [
    PERMISSIONS.PRODUCT_WRITE,
  ];
  readonly auditEntityType = 'Product';
  readonly auditAction = AuditAction.CREATE;

  constructor(
    private readonly products: ProductsService,
    private readonly prisma: PrismaService,
  ) {}

  async existsForKey(clientMutationId: string) {
    return (
      (await this.prisma.product.count({ where: { id: clientMutationId } })) > 0
    );
  }

  async validate(payload: unknown): Promise<ProductPayloadDto> {
    return validatePayload(ProductPayloadDto, payload);
  }

  async apply(
    payload: ProductPayloadDto,
    context: SyncMutationContext,
  ): Promise<SyncApplyResult> {
    if (payload.id !== context.clientMutationId) {
      throw new BusinessException(
        ErrorCode.VALIDATION_FAILED,
        'L’id du produit doit être la clé de la mutation',
        HttpStatus.UNPROCESSABLE_ENTITY,
      );
    }
    const prices = payload.prices ?? [];
    if (
      prices.length > 0 &&
      !context.user.permissions.includes(PERMISSIONS.PRICE_MANAGE)
    ) {
      throw new BusinessException(
        ErrorCode.FORBIDDEN_PERMISSION,
        'Permission requise pour fixer un prix : price.manage',
        HttpStatus.FORBIDDEN,
      );
    }
    ProductsService.assertCanSetCost(payload, context.user);
    const actor = { userId: context.user.id };
    // Déjà créé en ligne (réponse perdue) : on le reconnaît tel quel.
    const recognized =
      (await context.tx.product.count({
        where: { id: payload.id },
      })) > 0;
    const { prices: _ignored, ...product } = payload;
    let created = recognized
      ? null
      : await this.products.createInTx(context.tx, product, actor);
    for (const price of prices) {
      created = await this.products.setPriceInTx(
        context.tx,
        payload.id!,
        price,
        actor,
      );
    }
    return {
      entityId: payload.id!,
      serverState: {
        ...(created && { barcode: created.barcode, sku: created.sku }),
      },
      auditNewValue: {
        sku: payload.sku,
        name: payload.name,
        prices: prices.length,
        ...(recognized ? { alreadyRecordedOnline: true } : { offline: true }),
      },
    };
  }
}
