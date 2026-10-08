import { HttpStatus, Injectable } from '@nestjs/common';
import { ActorContext, writeAudit } from '../audit/audit-writer';
import { AuthenticatedUser } from '../common/auth.decorators';
import { BusinessException } from '../common/business.exception';
import { ErrorCode } from '../common/error-codes';
import { runOnce } from '../common/idempotency';
import { Customer, Prisma, Supplier } from '../generated/prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import { CreateReceptionDto } from '../receptions/dto/reception.dto';
import { ReceptionsService } from '../receptions/receptions.service';
import { CreateSaleDto } from '../sales/dto/sale.dto';
import { SalesService } from '../sales/sales.service';
import { SuppliersService } from '../suppliers/suppliers.service';
import {
  ConfrereDealDto,
  ConfrereDto,
  CreateConfrereDealDto,
  CreateConfrereDto,
} from './confreres.dto';

type Db = Prisma.TransactionClient;
type Confrere = Customer & { supplier: Supplier | null };

/// Confrères (décision MEDMEDBEN 2026-10-08) : un client relié à sa fiche
/// fournisseur. On lui vend (ventes, dette client sans plafond), on lui achète
/// (réception hors commande au magasin, dette fournisseur), on échange (les
/// deux à la fois). Ses règlements : encaissement client ; le versement À lui
/// reste un paiement fournisseur, réservé à l'admin.
@Injectable()
export class ConfreresService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly sales: SalesService,
    private readonly receptions: ReceptionsService,
  ) {}

  async findAll(): Promise<ConfrereDto[]> {
    const rows = await this.prisma.customer.findMany({
      where: { isActive: true, supplierId: { not: null } },
      include: { supplier: true },
      orderBy: { name: 'asc' },
    });
    return ConfreresService.withBalances(this.prisma, rows);
  }

  async create(
    dto: CreateConfrereDto,
    actor: ActorContext,
  ): Promise<ConfrereDto> {
    return this.prisma.$transaction(async (tx) => {
      const supplier = await tx.supplier.create({
        data: { name: dto.name, phone: dto.phone ?? null, notes: 'Confrère' },
      });
      const customer = await tx.customer.create({
        data: {
          id: dto.id,
          name: dto.name,
          phone: dto.phone ?? null,
          supplierId: supplier.id,
        },
        include: { supplier: true },
      });
      await writeAudit(tx, actor, {
        action: 'CREATE',
        entityType: 'Supplier',
        entityId: supplier.id,
        newValue: { name: supplier.name, confrere: true },
      });
      await writeAudit(tx, actor, {
        action: 'CREATE',
        entityType: 'Customer',
        entityId: customer.id,
        newValue: {
          name: customer.name,
          confrere: true,
          supplierId: supplier.id,
        },
      });
      return (await ConfreresService.withBalances(tx, [customer]))[0];
    });
  }

  async deal(
    id: string,
    dto: CreateConfrereDealDto,
    user: AuthenticatedUser,
    actor: ActorContext,
  ): Promise<ConfrereDealDto> {
    const confrere = await this.prisma.customer.findFirst({
      where: { id, isActive: true, supplierId: { not: null } },
      include: { supplier: true },
    });
    if (!confrere) {
      throw new BusinessException(
        ErrorCode.NOT_FOUND,
        'Confrère introuvable',
        HttpStatus.NOT_FOUND,
      );
    }
    const give = dto.give ?? [];
    if (give.length > 0 && !dto.saleMutationId) {
      throw new BusinessException(
        ErrorCode.VALIDATION_FAILED,
        'saleMutationId : obligatoire pour un échange',
        HttpStatus.UNPROCESSABLE_ENTITY,
      );
    }
    const store = await this.prisma.location.findFirst({
      where: { type: 'MAGASIN', isActive: true },
    });
    if (!store) {
      throw new BusinessException(
        ErrorCode.CONFLICT,
        'Aucun magasin actif',
        HttpStatus.CONFLICT,
      );
    }
    const reception: CreateReceptionDto = {
      clientMutationId: dto.clientMutationId,
      supplierId: confrere.supplierId!,
      locationId: store.id,
      lines: dto.receive,
      note: dto.note ?? null,
    };
    const sale: CreateSaleDto | null =
      give.length > 0
        ? {
            clientMutationId: dto.saleMutationId!,
            customerId: confrere.id,
            lines: give,
            paidAmount: 0,
          }
        : null;

    const done = await runOnce(
      async () => {
        const r = await this.receptions.replay(this.prisma, reception, user);
        if (!r) return null;
        const s = sale && (await this.sales.replay(this.prisma, sale, user));
        // Même clé d'achat, mais un échange qui n'avait pas eu lieu : autre opération.
        if (sale && !s) {
          throw new BusinessException(
            ErrorCode.CONFLICT,
            `Achat déjà enregistré (${r.number}) sans échange`,
            HttpStatus.CONFLICT,
          );
        }
        return { r, s };
      },
      () =>
        this.prisma.$transaction(async (tx) => {
          const r = await this.receptions.createInTx(
            tx,
            reception,
            user,
            actor,
            new Date(),
            true,
          );
          const s = sale ? await this.sales.createInTx(tx, sale, user) : null;
          // Règle 13 : un prix modifié reste tracé pour l'admin.
          const overrides = s ? SalesService.priceOverrides(s, sale!) : [];
          if (s && overrides.length > 0) {
            await writeAudit(tx, actor, {
              action: 'CREATE',
              entityType: 'Sale',
              entityId: s.id,
              newValue: { number: s.number, priceOverrides: overrides },
            });
          }
          return { r, s };
        }),
    );
    return {
      receptionNumber: done.r.number,
      saleNumber: done.s?.number ?? null,
      confrere: (
        await ConfreresService.withBalances(this.prisma, [confrere])
      )[0],
    };
  }

  /// Soldes des deux côtés, par les MÊMES règles que les fiches client et
  /// fournisseur (jamais recopiées).
  private static async withBalances(
    db: Db | PrismaService,
    rows: Confrere[],
  ): Promise<ConfrereDto[]> {
    const debts = await SalesService.customerDebts(
      db,
      rows.map((c) => c.id),
    );
    // ponytail: 3 requêtes de dette fournisseur par confrère — un magasin en a
    // quelques-uns ; passer en groupBy si la liste grossit.
    return Promise.all(
      rows.map(async (c) => {
        const { balanceDue } = await SuppliersService.debt(db, c.supplier!);
        const theyOwe = debts.get(c.id) ?? 0;
        return {
          id: c.id,
          supplierId: c.supplierId!,
          name: c.name,
          phone: c.phone,
          theyOwe,
          weOwe: balanceDue,
          net: theyOwe - balanceDue,
        };
      }),
    );
  }
}
