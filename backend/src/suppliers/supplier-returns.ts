import {
  Body,
  Controller,
  Get,
  HttpStatus,
  Injectable,
  Ip,
  Param,
  Post,
  StreamableFile,
} from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import {
  ApiBearerAuth,
  ApiCreatedResponse,
  ApiOkResponse,
  ApiOperation,
  ApiProduces,
  ApiProperty,
  ApiPropertyOptional,
  ApiTags,
} from '@nestjs/swagger';
import { Transform, Type } from 'class-transformer';
import {
  ArrayMaxSize,
  ArrayNotEmpty,
  IsArray,
  IsOptional,
  IsString,
  MaxLength,
  MinLength,
  ValidateNested,
} from 'class-validator';
import { ActorContext, writeAudit } from '../audit/audit-writer';
import {
  AuthenticatedUser,
  CurrentUser,
  RequirePermissions,
  RoleCode,
  Roles,
} from '../common/auth.decorators';
import { BusinessException } from '../common/business.exception';
import { CanonicalUuidPipe } from '../common/canonical-uuid.pipe';
import { nextDocumentNumber } from '../common/document-number';
import { ErrorCode } from '../common/error-codes';
import {
  assertSameMutation,
  ClientMutationId,
  runOnce,
} from '../common/idempotency';
import { roundMoney } from '../common/money';
import { formatDA, formatDateTime } from '../common/pdf/pdf';
import { PERMISSIONS } from '../common/permissions';
import { formatQuantity, parseQuantity } from '../common/quantity';
import { ClientGeneratedId, IsCanonicalUuid } from '../common/validation';
import { Prisma } from '../generated/prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import { renderA4Document } from '../sales/sale-document';
import { storeIdentity } from '../settings/store-settings';
import { StockLedgerService } from '../stock/stock-ledger.service';

type Db = Prisma.TransactionClient;

// ── Contrat ──────────────────────────────────────────────────────────────────

export class SupplierReturnLineInputDto {
  @ApiProperty() @IsCanonicalUuid() productId!: string;

  @ApiProperty({ example: '2.000' })
  @IsString()
  @MaxLength(20)
  quantity!: string;
}

export class CreateSupplierReturnDto {
  @ApiProperty({ description: 'UUID généré par le client.' })
  @ClientGeneratedId()
  id!: string;

  @ClientMutationId()
  clientMutationId!: string;

  @ApiProperty() @IsCanonicalUuid() supplierId!: string;

  @ApiPropertyOptional({ description: 'Commande concernée (facultatif).' })
  @IsCanonicalUuid()
  @IsOptional()
  purchaseOrderId?: string;

  @ApiProperty({ description: 'Lieu d’où part la marchandise (dépôt).' })
  @IsCanonicalUuid()
  locationId!: string;

  @ApiProperty({ type: [SupplierReturnLineInputDto] })
  @IsArray()
  @ArrayNotEmpty()
  @ArrayMaxSize(200)
  @ValidateNested({ each: true })
  @Type(() => SupplierReturnLineInputDto)
  lines!: SupplierReturnLineInputDto[];

  @ApiProperty({ example: 'Lot défectueux' })
  @Transform(({ value }: { value: unknown }) =>
    typeof value === 'string' ? value.trim() : value,
  )
  @IsString()
  @MinLength(2, {
    message: 'reason : motif obligatoire (2 caractères au moins)',
  })
  @MaxLength(300)
  reason!: string;
}

export class SupplierReturnDto {
  @ApiProperty() id!: string;
  @ApiProperty({ example: 'RF-2026-00001' }) number!: string;
  @ApiProperty() supplierId!: string;
  @ApiProperty({ nullable: true }) purchaseOrderId!: string | null;
  @ApiProperty() locationId!: string;
  @ApiProperty() totalHt!: number;
  @ApiProperty() totalTax!: number;
  @ApiProperty() totalTtc!: number;
  @ApiProperty() reason!: string;
  @ApiProperty() createdAt!: Date;
}

// ── Service ──────────────────────────────────────────────────────────────────

/// Retour fournisseur (P1 bis n°21l) : marchandise renvoyée, dans UNE
/// transaction (règle 3) — stock RETOUR_FOURNISSEUR (journal, jamais sous 0),
/// dette fournisseur réduite du TTC (lue par `SuppliersService.debt`), numéro
/// RF-AAAA-NNNNN, audit. Le prix n'est JAMAIS saisi : c'est le dernier prix
/// RÉCEPTIONNÉ de ce produit chez ce fournisseur (sa TVA figée) ; la quantité
/// est bornée par ce qui a été reçu de lui et pas encore renvoyé.
@Injectable()
export class SupplierReturnsService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly config: ConfigService,
    private readonly ledger: StockLedgerService,
  ) {}

  async create(
    dto: CreateSupplierReturnDto,
    user: AuthenticatedUser,
    actor: ActorContext,
  ): Promise<SupplierReturnDto> {
    const replay = async () => {
      const done = await this.prisma.supplierReturn.findUnique({
        where: { clientMutationId: dto.clientMutationId },
        include: { lines: true },
      });
      if (!done) return null;
      const key = (lines: { productId: string; quantity: string }[]) =>
        lines
          .map(
            (l) =>
              `${l.productId}|${formatQuantity(parseQuantity(l.quantity))}`,
          )
          .sort()
          .join(',');
      assertSameMutation(
        done,
        user.id,
        done.supplierId === dto.supplierId &&
          key(dto.lines) ===
            key(
              done.lines.map((l) => ({
                productId: l.productId,
                quantity: l.quantity.toFixed(3),
              })),
            ),
        {
          code: ErrorCode.CONFLICT,
          message: 'Ce retour fournisseur a déjà été enregistré autrement',
        },
      );
      return SupplierReturnsService.toDto(done);
    };
    return runOnce(replay, () =>
      this.prisma.$transaction((tx) => this.createInTx(tx, dto, user, actor)),
    );
  }

  private async createInTx(
    tx: Db,
    dto: CreateSupplierReturnDto,
    user: AuthenticatedUser,
    actor: ActorContext,
  ): Promise<SupplierReturnDto> {
    await tx.$queryRaw`SELECT "id" FROM "Supplier" WHERE "id" = ${dto.supplierId}::uuid FOR UPDATE`;
    const supplier = await tx.supplier.findUnique({
      where: { id: dto.supplierId },
    });
    if (!supplier) {
      throw new BusinessException(
        ErrorCode.NOT_FOUND,
        'Fournisseur introuvable',
        HttpStatus.NOT_FOUND,
      );
    }
    if (dto.purchaseOrderId) {
      const order = await tx.purchaseOrder.findUnique({
        where: { id: dto.purchaseOrderId },
      });
      if (order?.supplierId !== dto.supplierId) {
        throw new BusinessException(
          ErrorCode.VALIDATION_FAILED,
          'purchaseOrderId : commande d’un autre fournisseur',
          HttpStatus.UNPROCESSABLE_ENTITY,
        );
      }
    }
    const productIds = dto.lines.map((l) => l.productId);
    if (new Set(productIds).size !== productIds.length) {
      throw new BusinessException(
        ErrorCode.VALIDATION_FAILED,
        'lines : un produit par ligne',
        HttpStatus.UNPROCESSABLE_ENTITY,
      );
    }
    // Reçu de CE fournisseur, et déjà renvoyé : la borne du retour.
    const [received, sentBack] = await Promise.all([
      tx.receptionLine.groupBy({
        by: ['productId'],
        where: {
          productId: { in: productIds },
          reception: { supplierId: supplier.id },
        },
        _sum: { receivedQuantity: true },
      }),
      tx.supplierReturnLine.groupBy({
        by: ['productId'],
        where: {
          productId: { in: productIds },
          supplierReturn: { supplierId: supplier.id },
        },
        _sum: { quantity: true },
      }),
    ]);
    const lines: {
      productId: string;
      quantity: Prisma.Decimal;
      unitPriceHt: number;
      taxRate: Prisma.Decimal;
      lineTotalHt: number;
      lineTaxAmount: number;
      lineTotalTtc: number;
    }[] = [];
    for (const input of dto.lines) {
      const quantity = parseQuantity(input.quantity, 'lines.quantity');
      const got =
        received.find((r) => r.productId === input.productId)?._sum
          .receivedQuantity ?? new Prisma.Decimal(0);
      const gone =
        sentBack.find((r) => r.productId === input.productId)?._sum.quantity ??
        new Prisma.Decimal(0);
      const left = got.minus(gone);
      if (quantity.lessThanOrEqualTo(0) || quantity.greaterThan(left)) {
        throw new BusinessException(
          ErrorCode.VALIDATION_FAILED,
          `Quantité renvoyée invalide : au plus ${formatQuantity(left)} ` +
            '(reçu de ce fournisseur et pas encore renvoyé)',
          HttpStatus.UNPROCESSABLE_ENTITY,
        );
      }
      // Dernière réception de ce produit chez lui : son prix (jamais un prix
      // saisi) et son TTC figé — le renvoi retire de la dette, au prorata,
      // exactement ce que la réception y avait ajouté.
      const last = await tx.receptionLine.findFirst({
        where: {
          productId: input.productId,
          reception: { supplierId: supplier.id },
        },
        orderBy: { reception: { createdAt: 'desc' } },
        select: {
          unitPriceHt: true,
          receivedQuantity: true,
          lineTotalTtc: true,
          purchaseLine: { select: { taxRate: true } },
          product: { select: { taxRate: { select: { rate: true } } } },
        },
      });
      const unitPriceHt = last!.unitPriceHt;
      const taxRate =
        last!.purchaseLine?.taxRate ??
        last!.product.taxRate?.rate ??
        new Prisma.Decimal(0);
      const lineTotalHt = roundMoney(
        new Prisma.Decimal(unitPriceHt).mul(quantity),
      );
      const lineTotalTtc = Math.max(
        lineTotalHt,
        roundMoney(
          new Prisma.Decimal(last!.lineTotalTtc)
            .mul(quantity)
            .div(last!.receivedQuantity),
        ),
      );
      const lineTaxAmount = lineTotalTtc - lineTotalHt;
      lines.push({
        productId: input.productId,
        quantity,
        unitPriceHt,
        taxRate,
        lineTotalHt,
        lineTaxAmount,
        lineTotalTtc,
      });
    }
    const totalHt = lines.reduce((s, l) => s + l.lineTotalHt, 0);
    const totalTax = lines.reduce((s, l) => s + l.lineTaxAmount, 0);
    const number = await nextDocumentNumber(tx, 'RETOUR_FOURNISSEUR', 'RF', 5);
    const created = await tx.supplierReturn.create({
      data: {
        id: dto.id,
        number,
        supplierId: supplier.id,
        purchaseOrderId: dto.purchaseOrderId ?? null,
        userId: user.id,
        locationId: dto.locationId,
        totalHt,
        totalTax,
        totalTtc: totalHt + totalTax,
        reason: dto.reason,
        clientMutationId: dto.clientMutationId,
        lines: { create: lines },
      },
      include: { lines: true },
    });
    for (const l of [...lines].sort((a, b) =>
      a.productId.localeCompare(b.productId),
    )) {
      await this.ledger.applyMovement(tx, {
        productId: l.productId,
        locationId: dto.locationId,
        quantity: l.quantity.negated(),
        type: 'RETOUR_FOURNISSEUR',
        operationType: 'SUPPLIER_RETURN',
        operationId: created.id,
        userId: user.id,
        comment: `Retour ${number} à ${supplier.name}`,
      });
    }
    await writeAudit(tx, actor, {
      action: 'CREATE',
      entityType: 'SupplierReturn',
      entityId: created.id,
      newValue: {
        number,
        supplier: supplier.name,
        totalTtc: created.totalTtc,
        reason: dto.reason,
      },
    });
    return SupplierReturnsService.toDto(created);
  }

  async forSupplier(supplierId: string): Promise<SupplierReturnDto[]> {
    const rows = await this.prisma.supplierReturn.findMany({
      where: { supplierId },
      orderBy: { createdAt: 'desc' },
      take: 200,
    });
    return rows.map(SupplierReturnsService.toDto);
  }

  /// Bon de retour fournisseur (A4, accompagne la marchandise).
  async renderDocument(id: string): Promise<{ filename: string; pdf: Buffer }> {
    const row = await this.prisma.supplierReturn.findUnique({
      where: { id },
      include: { lines: true, supplier: true },
    });
    if (!row) {
      throw new BusinessException(
        ErrorCode.NOT_FOUND,
        'Retour introuvable',
        HttpStatus.NOT_FOUND,
      );
    }
    const products = await this.prisma.product.findMany({
      where: { id: { in: row.lines.map((l) => l.productId) } },
      select: { id: true, name: true, sku: true, unit: true },
    });
    const pdf = await renderA4Document({
      title: 'BON DE RETOUR',
      pdfTitle: `Retour fournisseur ${row.number}`,
      info: [`N° ${row.number}`, `Date : ${formatDateTime(row.createdAt)}`],
      store: await storeIdentity(this.prisma, this.config, false),
      partyLabel: 'Fournisseur',
      customer: {
        name: row.supplier.name,
        address: row.supplier.address,
        phone: row.supplier.phone,
      },
      products: new Map(products.map((p) => [p.id, p])),
      lines: row.lines.map((l) => ({
        productId: l.productId,
        quantity: formatQuantity(l.quantity),
        unitPriceHt: l.unitPriceHt,
        taxRate: l.taxRate.toFixed(2),
        lineTotalHt: l.lineTotalHt,
        lineTaxAmount: l.lineTaxAmount,
      })),
      totalHt: row.totalHt,
      totalTtc: row.totalTtc,
      after: [['À déduire de notre dette', formatDA(row.totalTtc)]],
      footer: `Motif : ${row.reason}`,
    });
    return { filename: `${row.number}.pdf`, pdf };
  }

  static toDto(row: {
    id: string;
    number: string;
    supplierId: string;
    purchaseOrderId: string | null;
    locationId: string;
    totalHt: number;
    totalTax: number;
    totalTtc: number;
    reason: string;
    createdAt: Date;
  }): SupplierReturnDto {
    return {
      id: row.id,
      number: row.number,
      supplierId: row.supplierId,
      purchaseOrderId: row.purchaseOrderId,
      locationId: row.locationId,
      totalHt: row.totalHt,
      totalTax: row.totalTax,
      totalTtc: row.totalTtc,
      reason: row.reason,
      createdAt: row.createdAt,
    };
  }
}

// ── Routes ───────────────────────────────────────────────────────────────────

/// Mêmes gardes que la RÉCEPTION (ADMIN|MAGASINIER + `reception.create`) :
/// c'est son opération inverse — la dette fournisseur baisse du TTC renvoyé.
@ApiTags('Fournisseurs')
@ApiBearerAuth()
@Controller()
@Roles(RoleCode.ADMIN, RoleCode.MAGASINIER)
@RequirePermissions(PERMISSIONS.RECEPTION_CREATE)
export class SupplierReturnsController {
  constructor(private readonly returns: SupplierReturnsService) {}

  @Post('supplier-returns')
  @ApiOperation({
    summary: 'Retour fournisseur : stock sortant, dette réduite, bon RF',
  })
  @ApiCreatedResponse({ type: SupplierReturnDto })
  create(
    @Body() dto: CreateSupplierReturnDto,
    @CurrentUser() user: AuthenticatedUser,
    @Ip() ip: string,
  ): Promise<SupplierReturnDto> {
    return this.returns.create(dto, user, { userId: user.id, ipAddress: ip });
  }

  @Get('suppliers/:id/returns')
  @ApiOperation({ summary: 'Retours à un fournisseur (200 plus récents)' })
  @ApiOkResponse({ type: [SupplierReturnDto] })
  list(
    @Param('id', CanonicalUuidPipe) id: string,
  ): Promise<SupplierReturnDto[]> {
    return this.returns.forSupplier(id);
  }

  @Get('supplier-returns/:id/pdf')
  @ApiOperation({ summary: 'Bon de retour fournisseur (PDF)' })
  @ApiProduces('application/pdf')
  @ApiOkResponse({ schema: { type: 'string', format: 'binary' } })
  async document(
    @Param('id', CanonicalUuidPipe) id: string,
  ): Promise<StreamableFile> {
    const { filename, pdf } = await this.returns.renderDocument(id);
    return new StreamableFile(pdf, {
      type: 'application/pdf',
      disposition: `inline; filename="${filename}"`,
    });
  }
}
