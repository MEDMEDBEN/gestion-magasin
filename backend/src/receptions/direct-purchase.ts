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

  @ApiProperty({ description: 'Prix d’achat unitaire HT, centimes (> 0).' })
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
export const directPurchaseKeys = (key: string) => ({
  MAGASIN: key,
  DEPOT: uuidv5(`${key}:DEPOT`, KEY_NAMESPACE),
});

type Line = {
  productId: string;
  receivedQuantity: string;
  unitPriceHt: number;
};
type Place = 'MAGASIN' | 'DEPOT';

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
      () => this.replay(this.prisma, dto, user),
      () =>
        this.prisma.$transaction((tx) => this.createInTx(tx, dto, user, actor)),
    );
  }

  /// Le plan de l'achat : la réception de CHAQUE lieu, telle qu'elle sera
  /// créée (même calcul pour créer et pour reconnaître un renvoi).
  private async plan(db: Db | PrismaService, dto: CreateDirectPurchaseDto) {
    const [store, depot] = await Promise.all(
      (['MAGASIN', 'DEPOT'] as const).map((type) =>
        db.location.findFirst({ where: { type, isActive: true } }),
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
    const buckets: Record<Place, Line[]> = { MAGASIN: [], DEPOT: [] };
    const split = new Set<string>();
    for (const line of dto.lines) {
      const toStore = qty(line.toStore, 'toStore');
      const toSplit = qty(line.toSplit, 'toSplit');
      const toDepot = qty(line.toDepot, 'toDepot').plus(toSplit);
      if (!toSplit.isZero()) split.add(line.productId);
      if (toStore.isZero() && toDepot.isZero()) {
        throw new BusinessException(
          ErrorCode.VALIDATION_FAILED,
          'Chaque ligne doit porter une quantité',
          HttpStatus.UNPROCESSABLE_ENTITY,
        );
      }
      for (const [place, q] of [
        ['MAGASIN', toStore],
        ['DEPOT', toDepot],
      ] as const) {
        if (!q.isZero()) {
          buckets[place].push({
            productId: line.productId,
            receivedQuantity: q.toFixed(3),
            unitPriceHt: line.unitPriceHt,
          });
        }
      }
    }
    const keys = directPurchaseKeys(dto.clientMutationId);
    const places = (['MAGASIN', 'DEPOT'] as const).filter(
      (p) => buckets[p].length > 0,
    );
    const receptions = places.map((place, i) => ({
      clientMutationId: keys[place],
      id: keys[place],
      supplierId: dto.supplierId,
      locationId: place === 'MAGASIN' ? store.id : depot.id,
      lines: buckets[place],
      note: dto.note ?? null,
      // Le paiement part avec la DERNIÈRE : la dette contient tout l'achat.
      ...(i === places.length - 1 &&
        dto.paidAmount && {
          payment: { amount: dto.paidAmount, fromCash: false },
        }),
    }));
    return { receptions, split };
  }

  /// Renvoi (réponse perdue) : les réceptions de CETTE clé — du MÊME auteur
  /// et du MÊME contenu (`ReceptionsService.replay` le vérifie), TOUTES
  /// présentes ; sinon conflit (panier modifié depuis, clé d'un autre compte).
  async replay(
    db: Db | PrismaService,
    dto: CreateDirectPurchaseDto,
    user: AuthenticatedUser,
  ): Promise<DirectPurchaseDto | null> {
    const keys = Object.values(directPurchaseKeys(dto.clientMutationId));
    const any = await db.reception.count({
      where: { clientMutationId: { in: keys } },
    });
    if (any === 0) return null;
    const { receptions: planned } = await this.plan(db, dto);
    const found: ReceptionDto[] = [];
    for (const place of planned) {
      const existing = await this.receptions.replay(db, place, user);
      if (existing) found.push(existing);
    }
    if (found.length !== planned.length || found.length !== any) {
      throw new BusinessException(
        ErrorCode.CONFLICT,
        'Achat déjà enregistré avec un autre contenu : vérifiez avant de le refaire',
        HttpStatus.CONFLICT,
      );
    }
    return { receptions: found };
  }

  /// Une réception par lieu servi (règle 6 : le stock suit ce qui entre),
  /// TOUT dans la transaction de l'appelant (règle 3).
  async createInTx(
    tx: Db,
    dto: CreateDirectPurchaseDto,
    user: AuthenticatedUser,
    actor: ActorContext | null,
    receivedAt: Date = new Date(),
  ): Promise<DirectPurchaseDto> {
    const { receptions: planned, split } = await this.plan(tx, dto);
    const receptions: ReceptionDto[] = [];
    for (const place of planned) {
      receptions.push(
        await this.receptions.createInTx(tx, place, user, actor, receivedAt),
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
