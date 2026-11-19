import { HttpStatus, Injectable } from '@nestjs/common';
import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import { Transform, Type } from 'class-transformer';
import {
  ArrayMaxSize,
  ArrayNotEmpty,
  IsArray,
  IsInt,
  IsOptional,
  IsString,
  Max,
  MaxLength,
  Min,
  ValidateNested,
} from 'class-validator';
import { v5 as uuidv5 } from 'uuid';
import { ActorContext } from '../audit/audit-writer';
import { AuthenticatedUser } from '../common/auth.decorators';
import { BusinessException } from '../common/business.exception';
import { ErrorCode } from '../common/error-codes';
import { ClientMutationId } from '../common/idempotency';
import { runOnce } from '../common/idempotency';
import { parseQuantity } from '../common/quantity';
import { IsCanonicalUuid } from '../common/validation';
import { Prisma } from '../generated/prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import { MAX_MONEY } from '../sales/dto/sale.dto';
import { ReceptionDto } from './dto/reception.dto';
import { ReceptionsService } from './receptions.service';

type Db = Prisma.TransactionClient;

/// Une ligne du PANIER D'ACHAT : où va la marchandise — magasin, dépôt, et/ou
/// « en total » (posé au dépôt, à répartir ensuite). Quantités ≥ 0, décimales
/// en chaîne (règle 10) ; au moins une > 0.
export class DirectPurchaseLineDto {
  @ApiProperty() @IsCanonicalUuid() productId!: string;

  @ApiProperty({ description: 'Prix d’achat unitaire HT, centimes (≥ 0).' })
  @IsInt()
  @Min(0)
  @Max(MAX_MONEY)
  unitPriceHt!: number;

  @ApiPropertyOptional({ example: '5.000' })
  @IsString()
  @MaxLength(20)
  @IsOptional()
  toStore?: string;

  @ApiPropertyOptional({ example: '10.000' })
  @IsString()
  @MaxLength(20)
  @IsOptional()
  toDepot?: string;

  @ApiPropertyOptional({
    example: '20.000',
    description: 'Quantité « en total » : posée au dépôt, à répartir.',
  })
  @IsString()
  @MaxLength(20)
  @IsOptional()
  toSplit?: string;
}

/// ACHAT DIRECT (demande MEDMEDBEN du 2026-11-19) : plus de commande puis
/// réception — le panier d'achat entre en stock d'un coup, et ce qui est payé
/// au fournisseur se déduit ; le reste devient sa dette.
export class CreateDirectPurchaseDto {
  @ClientMutationId() clientMutationId!: string;

  @ApiProperty() @IsCanonicalUuid() supplierId!: string;

  @ApiProperty({ type: [DirectPurchaseLineDto] })
  @IsArray()
  @ArrayNotEmpty()
  @ArrayMaxSize(200)
  @ValidateNested({ each: true })
  @Type(() => DirectPurchaseLineDto)
  lines!: DirectPurchaseLineDto[];

  @ApiPropertyOptional({
    description:
      'Payé au fournisseur (centimes, > 0) ; absent = rien payé (tout en dette).',
  })
  @IsInt()
  @Min(1)
  @Max(MAX_MONEY)
  @IsOptional()
  paidAmount?: number;

  @ApiPropertyOptional()
  @Transform(({ value }: { value: unknown }) =>
    typeof value === 'string' ? value.trim() || null : value,
  )
  @IsString()
  @MaxLength(500)
  @IsOptional()
  note?: string | null;
}

export class DirectPurchaseDto {
  @ApiProperty({ type: [ReceptionDto] }) receptions!: ReceptionDto[];
}

/// Espace de noms des clés dérivées (une réception par lieu).
const KEY_NAMESPACE = '5b0f4f2a-9c1e-4d6a-8e3b-2f7c1a9d0e44';
const keyFor = (key: string, place: 'MAGASIN' | 'DEPOT') =>
  place === 'MAGASIN' ? key : uuidv5(`${key}:DEPOT`, KEY_NAMESPACE);

@Injectable()
export class DirectPurchaseService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly receptions: ReceptionsService,
  ) {}

  async create(
    dto: CreateDirectPurchaseDto,
    user: AuthenticatedUser,
    actor: ActorContext,
  ): Promise<DirectPurchaseDto> {
    return runOnce(
      () => this.replay(this.prisma, dto),
      () =>
        this.prisma.$transaction((tx) => this.createInTx(tx, dto, user, actor)),
    );
  }

  /// Renvoi (réponse perdue) : les réceptions de CETTE clé, telles quelles.
  async replay(db: Db | PrismaService, dto: CreateDirectPurchaseDto) {
    const keys = [
      keyFor(dto.clientMutationId, 'MAGASIN'),
      keyFor(dto.clientMutationId, 'DEPOT'),
    ];
    const found = await db.reception.findMany({
      where: { clientMutationId: { in: keys } },
      select: { id: true },
    });
    if (found.length === 0) return null;
    return {
      receptions: await Promise.all(
        found.map((r) => this.receptions.findOne(r.id)),
      ),
    };
  }

  /// Une réception par lieu servi (règle 6 : le stock suit ce qui entre),
  /// TOUT dans la transaction de l'appelant (règle 3) ; le paiement part avec
  /// la DERNIÈRE, quand la dette contient tout l'achat.
  async createInTx(
    tx: Db,
    dto: CreateDirectPurchaseDto,
    user: AuthenticatedUser,
    actor: ActorContext | null,
    receivedAt: Date = new Date(),
  ): Promise<DirectPurchaseDto> {
    const [store, depot] = await Promise.all(
      (['MAGASIN', 'DEPOT'] as const).map((type) =>
        tx.location.findFirst({ where: { type, isActive: true } }),
      ),
    );
    if (!store || !depot) {
      throw new BusinessException(
        ErrorCode.VALIDATION_FAILED,
        'Magasin ou dépôt introuvable',
        HttpStatus.UNPROCESSABLE_ENTITY,
      );
    }
    const qty = (raw: string | undefined, field: string) => {
      if (raw === undefined || raw.trim() === '') return new Prisma.Decimal(0);
      const q = parseQuantity(raw, field);
      if (q.isNegative()) {
        throw new BusinessException(
          ErrorCode.VALIDATION_FAILED,
          `${field} : une quantité achetée ne peut pas être négative`,
          HttpStatus.UNPROCESSABLE_ENTITY,
        );
      }
      return q;
    };
    const buckets = { MAGASIN: [] as Line[], DEPOT: [] as Line[] };
    type Line = {
      productId: string;
      receivedQuantity: string;
      unitPriceHt: number;
    };
    const split = new Set<string>();
    for (const line of dto.lines) {
      const toStore = qty(line.toStore, 'toStore');
      const toDepot = qty(line.toDepot, 'toDepot').plus(
        qty(line.toSplit, 'toSplit'),
      );
      if (!qty(line.toSplit, 'toSplit').isZero()) split.add(line.productId);
      if (toStore.isZero() && toDepot.isZero()) {
        throw new BusinessException(
          ErrorCode.VALIDATION_FAILED,
          'Chaque ligne doit porter une quantité',
          HttpStatus.UNPROCESSABLE_ENTITY,
        );
      }
      if (!toStore.isZero()) {
        buckets.MAGASIN.push({
          productId: line.productId,
          receivedQuantity: toStore.toFixed(3),
          unitPriceHt: line.unitPriceHt,
        });
      }
      if (!toDepot.isZero()) {
        buckets.DEPOT.push({
          productId: line.productId,
          receivedQuantity: toDepot.toFixed(3),
          unitPriceHt: line.unitPriceHt,
        });
      }
    }
    const places = (['MAGASIN', 'DEPOT'] as const).filter(
      (p) => buckets[p].length > 0,
    );
    const receptions: ReceptionDto[] = [];
    for (const [i, place] of places.entries()) {
      const last = i === places.length - 1;
      receptions.push(
        await this.receptions.createInTx(
          tx,
          {
            clientMutationId: keyFor(dto.clientMutationId, place),
            id: keyFor(dto.clientMutationId, place),
            supplierId: dto.supplierId,
            locationId: place === 'MAGASIN' ? store.id : depot.id,
            lines: buckets[place],
            note: dto.note ?? null,
            ...(last &&
              dto.paidAmount && {
                payment: { amount: dto.paidAmount, fromCash: false },
              }),
          },
          user,
          actor,
          receivedAt,
        ),
      );
    }
    if (split.size > 0) {
      await tx.product.updateMany({
        where: { id: { in: [...split] } },
        data: { splitPending: true },
      });
    }
    return { receptions };
  }
}
