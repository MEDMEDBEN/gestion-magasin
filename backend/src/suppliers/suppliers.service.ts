import { HttpStatus, Injectable } from '@nestjs/common';
import { ActorContext, writeAudit } from '../audit/audit-writer';
import { AuthenticatedUser } from '../common/auth.decorators';
import { BusinessException } from '../common/business.exception';
import { ErrorCode } from '../common/error-codes';
import { assertSameMutation, runOnce } from '../common/idempotency';
import { Prisma, Supplier } from '../generated/prisma/client';
import { parseSort } from '../common/dto/pagination.dto';
import { PrismaService } from '../prisma/prisma.service';
import { formatDA } from '../common/pdf/pdf';
import { CashSessionsService } from '../sales/cash-sessions.service';
import {
  CreateSupplierDto,
  CreateSupplierPaymentDto,
  SupplierDto,
  SupplierListDto,
  SupplierListQueryDto,
  SupplierPaymentDto,
  UpdateSupplierDto,
} from './dto/supplier.dto';

type Db = Prisma.TransactionClient;

/// Tris autorisés (liste blanche, CONVENTIONS.md).
const SUPPLIER_SORT_FIELDS = ['name', 'createdAt'] as const;

@Injectable()
export class SuppliersService {
  constructor(private readonly prisma: PrismaService) {}

  /// Dette fournisseur (règle : jamais stockée, toujours recalculée) :
  /// reprise de l'existant − paiements. Les achats (P0 #6) s'y ajouteront.
  static async debt(db: Db | PrismaService, supplier: Supplier) {
    const paid = await db.supplierPayment.aggregate({
      where: { supplierId: supplier.id },
      _sum: { amount: true },
    });
    const paidAmount = paid._sum.amount ?? 0;
    return { paidAmount, balanceDue: supplier.openingBalance - paidAmount };
  }

  async findAll(query: SupplierListQueryDto): Promise<SupplierListDto> {
    const where: Prisma.SupplierWhereInput = {
      ...(!query.includeInactive && { isActive: true }),
      ...(query.q && {
        OR: [
          { name: { contains: query.q, mode: 'insensitive' } },
          { phone: { contains: query.q } },
          { code: { contains: query.q, mode: 'insensitive' } },
        ],
      }),
    };
    const [rows, total] = await Promise.all([
      this.prisma.supplier.findMany({
        where,
        skip: (query.page - 1) * query.limit,
        take: query.limit,
        orderBy: [
          parseSort(query.sort, SUPPLIER_SORT_FIELDS, { name: 'asc' }),
          { id: 'asc' },
        ],
      }),
      this.prisma.supplier.count({ where }),
    ]);
    // Un seul agrégat pour toute la page (et non une requête par fournisseur).
    const paid = await this.prisma.supplierPayment.groupBy({
      by: ['supplierId'],
      where: { supplierId: { in: rows.map((r) => r.id) } },
      _sum: { amount: true },
    });
    const paidBy = new Map(paid.map((p) => [p.supplierId, p._sum.amount ?? 0]));
    const data = rows.map((row) =>
      SuppliersService.toDtoWith(row, paidBy.get(row.id) ?? 0),
    );
    return { data, meta: { page: query.page, limit: query.limit, total } };
  }

  async findOne(id: string): Promise<SupplierDto> {
    const supplier = await this.prisma.supplier.findUnique({ where: { id } });
    if (!supplier) throw SuppliersService.notFound();
    return this.toDto(this.prisma, supplier);
  }

  async create(
    dto: CreateSupplierDto,
    actor: ActorContext,
  ): Promise<SupplierDto> {
    return this.prisma.$transaction(async (tx) => {
      const supplier = await tx.supplier.create({
        data: {
          id: dto.id,
          name: dto.name,
          phone: dto.phone ?? null,
          email: dto.email ?? null,
          address: dto.address ?? null,
          contactName: dto.contactName ?? null,
          notes: dto.notes ?? null,
          openingBalance: dto.openingBalance ?? 0,
        },
      });
      await writeAudit(tx, actor, {
        action: 'CREATE',
        entityType: 'Supplier',
        entityId: supplier.id,
        newValue: SuppliersService.snapshot(supplier),
      });
      return this.toDto(tx, supplier);
    });
  }

  async update(
    id: string,
    dto: UpdateSupplierDto,
    actor: ActorContext,
  ): Promise<SupplierDto> {
    return this.prisma.$transaction(async (tx) => {
      // Verrou : un paiement simultané ne doit pas passer sous une reprise revue.
      await tx.$queryRaw`SELECT "id" FROM "Supplier" WHERE "id" = ${id}::uuid FOR UPDATE`;
      const before = await tx.supplier.findUnique({ where: { id } });
      if (!before) throw SuppliersService.notFound();
      if (dto.openingBalance !== undefined) {
        const { paidAmount } = await SuppliersService.debt(tx, before);
        if (dto.openingBalance < paidAmount) {
          throw new BusinessException(
            ErrorCode.VALIDATION_FAILED,
            `Déjà payé ${paidAmount} centimes à ce fournisseur : la reprise ne peut pas être inférieure`,
            HttpStatus.UNPROCESSABLE_ENTITY,
          );
        }
      }
      const supplier = await tx.supplier.update({
        where: { id },
        data: {
          ...(dto.name !== undefined && { name: dto.name }),
          ...(dto.phone !== undefined && { phone: dto.phone }),
          ...(dto.email !== undefined && { email: dto.email }),
          ...(dto.address !== undefined && { address: dto.address }),
          ...(dto.contactName !== undefined && {
            contactName: dto.contactName,
          }),
          ...(dto.notes !== undefined && { notes: dto.notes }),
          ...(dto.openingBalance !== undefined && {
            openingBalance: dto.openingBalance,
          }),
          ...(dto.isActive !== undefined && { isActive: dto.isActive }),
        },
      });
      const [was, now] = [
        SuppliersService.snapshot(before),
        SuppliersService.snapshot(supplier),
      ];
      if (JSON.stringify(was) !== JSON.stringify(now)) {
        await writeAudit(tx, actor, {
          action: 'UPDATE',
          entityType: 'Supplier',
          entityId: id,
          oldValue: was,
          newValue: now,
        });
      }
      return this.toDto(tx, supplier);
    });
  }

  /// Paiement fournisseur (ADMIN) : jamais au-delà du reste dû. Payé depuis la
  /// caisse → SORTIE dans la session ouverte (règle 12, visible au rapport Z) ;
  /// sinon (virement, espèces hors tiroir) la caisse n'est pas touchée.
  async pay(
    dto: CreateSupplierPaymentDto,
    user: AuthenticatedUser,
    actor: ActorContext,
  ): Promise<SupplierPaymentDto> {
    // Idempotence (common/idempotency.ts) : un renvoi ne paie jamais deux fois.
    const replay = async () => {
      const existing = await this.prisma.supplierPayment.findUnique({
        where: { clientMutationId: dto.clientMutationId },
      });
      if (!existing) return null;
      assertSameMutation(
        existing,
        user.id,
        existing.supplierId === dto.supplierId &&
          existing.amount === dto.amount &&
          (existing.cashSessionId !== null) === dto.fromCash,
        {
          code: ErrorCode.PAYMENT_ALREADY_RECORDED,
          message: `Paiement déjà enregistré : ${formatDA(existing.amount)} — vérifiez avant d’en refaire un`,
        },
      );
      const supplier = await this.prisma.supplier.findUniqueOrThrow({
        where: { id: existing.supplierId },
      });
      const { balanceDue } = await SuppliersService.debt(this.prisma, supplier);
      return SuppliersService.paymentDto(existing, balanceDue);
    };
    return runOnce(replay, () =>
      this.prisma.$transaction(async (tx) => {
        await tx.$queryRaw`SELECT "id" FROM "Supplier" WHERE "id" = ${dto.supplierId}::uuid FOR UPDATE`;
        const supplier = await tx.supplier.findUnique({
          where: { id: dto.supplierId },
        });
        if (!supplier) throw SuppliersService.notFound();

        const { balanceDue } = await SuppliersService.debt(tx, supplier);
        if (dto.amount > balanceDue) {
          throw new BusinessException(
            ErrorCode.VALIDATION_FAILED,
            `Paiement supérieur au reste dû (${balanceDue} centimes)`,
            HttpStatus.UNPROCESSABLE_ENTITY,
          );
        }

        const session = dto.fromCash
          ? await CashSessionsService.lockOpenSession(tx, { userId: user.id })
          : null;
        if (dto.fromCash && !session) {
          throw new BusinessException(
            ErrorCode.CASH_SESSION_REQUIRED,
            'Ouvrez votre caisse avant de payer un fournisseur en espèces',
            HttpStatus.UNPROCESSABLE_ENTITY,
          );
        }

        const payment = await tx.supplierPayment.create({
          data: {
            id: dto.id,
            clientMutationId: dto.clientMutationId,
            supplierId: supplier.id,
            userId: user.id,
            cashSessionId: session?.id ?? null,
            amount: dto.amount,
            method: dto.fromCash ? 'ESPECES' : (dto.method ?? 'VIREMENT'),
            note: dto.note ?? null,
          },
        });
        if (session) {
          // Garde commun : jamais plus que le contenu du tiroir (CASH_INSUFFICIENT).
          await CashSessionsService.withdraw(tx, session, {
            userId: user.id,
            amount: dto.amount,
            // Rapprochement caisse ↔ paiement par l'id du paiement.
            note: `Paiement fournisseur ${payment.id} — ${supplier.name}`,
          });
        }
        await writeAudit(tx, actor, {
          action: 'CREATE',
          entityType: 'SupplierPayment',
          entityId: payment.id,
          newValue: {
            supplierId: supplier.id,
            amount: dto.amount,
            method: payment.method,
            fromCash: dto.fromCash,
          },
        });
        return SuppliersService.paymentDto(payment, balanceDue - dto.amount);
      }),
    );
  }

  private static paymentDto(
    payment: {
      id: string;
      supplierId: string;
      amount: number;
      method: string;
      cashSessionId: string | null;
      paidAt: Date;
    },
    balanceDue: number,
  ): SupplierPaymentDto {
    return {
      id: payment.id,
      supplierId: payment.supplierId,
      amount: payment.amount,
      method: payment.method,
      fromCash: payment.cashSessionId !== null,
      paidAt: payment.paidAt,
      balanceDue,
    };
  }

  private static snapshot(s: Supplier) {
    return {
      name: s.name,
      phone: s.phone,
      email: s.email,
      notes: s.notes,
      address: s.address,
      contactName: s.contactName,
      openingBalance: s.openingBalance,
      isActive: s.isActive,
    };
  }

  private static notFound() {
    return new BusinessException(
      ErrorCode.NOT_FOUND,
      'Fournisseur introuvable',
      HttpStatus.NOT_FOUND,
    );
  }

  private async toDto(
    db: Db | PrismaService,
    supplier: Supplier,
  ): Promise<SupplierDto> {
    const { paidAmount } = await SuppliersService.debt(db, supplier);
    return SuppliersService.toDtoWith(supplier, paidAmount);
  }

  private static toDtoWith(
    supplier: Supplier,
    paidAmount: number,
  ): SupplierDto {
    return {
      id: supplier.id,
      code: supplier.code,
      name: supplier.name,
      phone: supplier.phone,
      email: supplier.email,
      address: supplier.address,
      contactName: supplier.contactName,
      notes: supplier.notes,
      openingBalance: supplier.openingBalance,
      paidAmount,
      balanceDue: supplier.openingBalance - paidAmount,
      isActive: supplier.isActive,
    };
  }
}
