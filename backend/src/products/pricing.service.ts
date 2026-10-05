import { HttpStatus, Injectable } from '@nestjs/common';
import { ActorContext, writeAudit } from '../audit/audit-writer';
import { BusinessException } from '../common/business.exception';
import { ErrorCode } from '../common/error-codes';
import { Prisma, PriceTier } from '../generated/prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import { CreatePriceTierDto, UpdatePriceTierDto } from './dto/pricing.dto';
import { PriceTierDto } from './dto/product.dto';

type Db = Prisma.TransactionClient;

/// Écritures des tarifs : une à la fois (défaut unique).
const PRICING_LOCK = 7305;

/// Paramètres de prix (P1 bis n°21h) : les tarifs (la TVA est retirée depuis
/// le 2026-10-05, `sandbox/tva/`). Règles : code unique ; UN seul élément par défaut (en désigner un autre
/// retire l'ancien) ; le défaut ne se désactive pas ; un inactif n'est pas
/// le défaut. Chaque écriture est auditée. Un tarif désactivé n'efface rien :
/// ses clients retombent sur le tarif par défaut (règle de `priceCart`).
@Injectable()
export class PricingService {
  constructor(private readonly prisma: PrismaService) {}

  async priceTiers(includeInactive = false): Promise<PriceTierDto[]> {
    const rows = await this.prisma.priceTier.findMany({
      where: includeInactive ? {} : { isActive: true },
      orderBy: [{ isDefault: 'desc' }, { code: 'asc' }],
    });
    return rows.map(PricingService.tierToDto);
  }

  async createTier(
    dto: CreatePriceTierDto,
    actor: ActorContext,
  ): Promise<PriceTierDto> {
    return this.prisma.$transaction(async (tx) => {
      await PricingService.lock(tx);
      await PricingService.assertCodeFree(
        await tx.priceTier.findUnique({ where: { code: dto.code } }),
        dto.code,
      );
      const created = PricingService.tierToDto(
        await tx.priceTier.create({ data: { code: dto.code, name: dto.name } }),
      );
      await writeAudit(tx, actor, {
        action: 'CREATE',
        entityType: 'PriceTier',
        entityId: created.id,
        newValue: { ...created },
      });
      return created;
    });
  }

  async updateTier(
    id: string,
    dto: UpdatePriceTierDto,
    actor: ActorContext,
  ): Promise<PriceTierDto> {
    return this.prisma.$transaction(async (tx) => {
      await PricingService.lock(tx);
      const before = await tx.priceTier.findUnique({ where: { id } });
      if (!before) throw PricingService.notFound('Tarif');
      PricingService.assertDefaultRules(before, dto, 'tarif');
      if (dto.isDefault) {
        await tx.priceTier.updateMany({
          where: { isDefault: true, id: { not: id } },
          data: { isDefault: false },
        });
      }
      const after = PricingService.tierToDto(
        await tx.priceTier.update({ where: { id }, data: dto }),
      );
      const oldValue = { ...PricingService.tierToDto(before) };
      // Rien de changé (corps vide, valeurs identiques) : pas d'audit.
      if (JSON.stringify(oldValue) !== JSON.stringify({ ...after })) {
        await writeAudit(tx, actor, {
          action: 'UPDATE',
          entityType: 'PriceTier',
          entityId: id,
          oldValue,
          newValue: { ...after },
        });
      }
      return after;
    });
  }

  private static assertDefaultRules(
    before: { isDefault: boolean; isActive: boolean },
    dto: { isDefault?: true; isActive?: boolean },
    what: 'tarif',
  ): void {
    const active = dto.isActive ?? before.isActive;
    const isDefault = dto.isDefault ?? before.isDefault;
    if (isDefault && !active) {
      throw new BusinessException(
        ErrorCode.INVALID_STATE_TRANSITION,
        `Le ${what} par défaut ne peut pas être inactif : désignez d’abord un autre ${what} par défaut`,
        HttpStatus.CONFLICT,
      );
    }
  }

  private static async assertCodeFree(existing: unknown, code: string) {
    if (existing) {
      throw new BusinessException(
        ErrorCode.CONFLICT,
        `Code « ${code} » déjà utilisé`,
        HttpStatus.CONFLICT,
      );
    }
  }

  private static notFound(what: string) {
    return new BusinessException(
      ErrorCode.NOT_FOUND,
      `${what} introuvable`,
      HttpStatus.NOT_FOUND,
    );
  }

  private static async lock(tx: Db) {
    await tx.$executeRaw`SELECT pg_advisory_xact_lock(${PRICING_LOCK}::int, 0)`;
  }

  private static tierToDto(tier: PriceTier): PriceTierDto {
    return {
      id: tier.id,
      code: tier.code,
      name: tier.name,
      isDefault: tier.isDefault,
      isActive: tier.isActive,
    };
  }
}
