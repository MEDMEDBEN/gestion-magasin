import { HttpStatus, Injectable } from '@nestjs/common';
import { ActorContext, writeAudit } from '../audit/audit-writer';
import { AuthenticatedUser } from '../common/auth.decorators';
import { BusinessException } from '../common/business.exception';
import { ErrorCode } from '../common/error-codes';
import { assertSameMutation, runOnce } from '../common/idempotency';
import { formatDA } from '../common/pdf/pdf';
import { PERMISSIONS } from '../common/permissions';
import { Customer, Prisma } from '../generated/prisma/client';
import { parseSort } from '../common/dto/pagination.dto';
import {
  PaymentHistoryDto,
  ReversePaymentDto,
} from '../common/dto/payment.dto';
import { PaginationQueryDto } from '../common/dto/pagination.dto';
import { PrismaService } from '../prisma/prisma.service';
import { CashSessionsService } from '../sales/cash-sessions.service';
import { SalesService } from '../sales/sales.service';
import {
  CreateCustomerDto,
  CustomerDto,
  CustomerListDto,
  CustomerListQueryDto,
  CustomerPaymentDto,
  CreateCustomerPaymentDto,
  UpdateCustomerDto,
} from './dto/customer.dto';

type Db = Prisma.TransactionClient;

/// Tris autorisés (liste blanche, CONVENTIONS.md).
const CUSTOMER_SORT_FIELDS = ['name', 'createdAt'] as const;
const PAYMENT_SORT_FIELDS = ['paidAt', 'amount'] as const;

@Injectable()
export class CustomersService {
  constructor(private readonly prisma: PrismaService) {}

  async findAll(query: CustomerListQueryDto): Promise<CustomerListDto> {
    const where: Prisma.CustomerWhereInput = {
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
      this.prisma.customer.findMany({
        where,
        skip: (query.page - 1) * query.limit,
        take: query.limit,
        orderBy: [
          parseSort(query.sort, CUSTOMER_SORT_FIELDS, { name: 'asc' }),
          { id: 'asc' },
        ],
      }),
      this.prisma.customer.count({ where }),
    ]);
    // Dettes de toute la page en 2 requêtes (jamais 2 par client).
    const ids = rows.map((r) => r.id);
    const debts = await SalesService.customerDebts(this.prisma, ids);
    const overdue = await SalesService.customerOverdue(this.prisma, ids, debts);
    const data = rows.map((row) =>
      CustomersService.toDtoWith(
        row,
        debts.get(row.id) ?? 0,
        overdue.get(row.id) ?? 0,
      ),
    );
    return { data, meta: { page: query.page, limit: query.limit, total } };
  }

  async findOne(id: string): Promise<CustomerDto> {
    const customer = await this.prisma.customer.findUnique({ where: { id } });
    if (!customer) throw CustomersService.notFound();
    return this.toDto(this.prisma, customer);
  }

  async create(
    dto: CreateCustomerDto,
    user: AuthenticatedUser,
    actor: ActorContext,
  ): Promise<CustomerDto> {
    CustomersService.assertCommercialTermsAllowed(dto, user);
    return this.prisma.$transaction(async (tx) => {
      if (dto.priceTierId)
        await CustomersService.assertTier(tx, dto.priceTierId);
      const customer = await tx.customer.create({
        data: {
          id: dto.id,
          name: dto.name,
          phone: dto.phone ?? null,
          email: dto.email ?? null,
          address: dto.address ?? null,
          notes: dto.notes ?? null,
          priceTierId: dto.priceTierId ?? null,
          creditLimit: dto.creditLimit ?? 0,
        },
      });
      await writeAudit(tx, actor, {
        action: 'CREATE',
        entityType: 'Customer',
        entityId: customer.id,
        newValue: {
          name: customer.name,
          priceTierId: customer.priceTierId,
          creditLimit: customer.creditLimit,
        },
      });
      return this.toDto(tx, customer);
    });
  }

  async update(
    id: string,
    dto: UpdateCustomerDto,
    user: AuthenticatedUser,
    actor: ActorContext,
  ): Promise<CustomerDto> {
    CustomersService.assertCommercialTermsAllowed(dto, user);
    return this.prisma.$transaction(async (tx) => {
      const before = await tx.customer.findUnique({ where: { id } });
      if (!before) throw CustomersService.notFound();
      if (dto.priceTierId)
        await CustomersService.assertTier(tx, dto.priceTierId);
      const customer = await tx.customer.update({
        where: { id },
        data: {
          ...(dto.name !== undefined && { name: dto.name }),
          ...(dto.phone !== undefined && { phone: dto.phone }),
          ...(dto.email !== undefined && { email: dto.email }),
          ...(dto.address !== undefined && { address: dto.address }),
          ...(dto.notes !== undefined && { notes: dto.notes }),
          ...(dto.isActive !== undefined && { isActive: dto.isActive }),
          ...(dto.priceTierId !== undefined && {
            priceTierId: dto.priceTierId,
          }),
          ...(dto.creditLimit !== undefined && {
            creditLimit: dto.creditLimit,
          }),
        },
      });
      const snapshot = (c: Customer) => ({
        name: c.name,
        phone: c.phone,
        email: c.email,
        address: c.address,
        notes: c.notes,
        isActive: c.isActive,
        priceTierId: c.priceTierId,
        creditLimit: c.creditLimit,
      });
      if (
        JSON.stringify(snapshot(before)) !== JSON.stringify(snapshot(customer))
      ) {
        await writeAudit(tx, actor, {
          action: 'UPDATE',
          entityType: 'Customer',
          entityId: id,
          oldValue: snapshot(before),
          newValue: snapshot(customer),
        });
      }
      return this.toDto(tx, customer);
    });
  }

  /// Règlement d'une dette en ESPÈCES (seul moyen accepté, décision 2026-09-15) :
  /// il entre dans la caisse OUVERTE de celui qui encaisse (règle 12), jamais
  /// au-delà de ce qui est dû.
  async pay(
    dto: CreateCustomerPaymentDto,
    user: AuthenticatedUser,
    actor: ActorContext,
  ): Promise<CustomerPaymentDto> {
    // Idempotence (common/idempotency.ts) : une dette n'est jamais effacée deux
    // fois pour un seul règlement, même renvoyé après un délai dépassé.
    return runOnce(
      () => this.replayPayment(this.prisma, dto, user),
      () =>
        this.prisma.$transaction((tx) => this.payInTx(tx, dto, user, actor)),
    );
  }

  /// Règlement déjà enregistré sous cette clé (même contenu), ou `null`.
  /// Partagé avec la synchronisation : reconnu, jamais refait.
  async replayPayment(
    db: Prisma.TransactionClient,
    dto: CreateCustomerPaymentDto,
    user: AuthenticatedUser,
  ): Promise<CustomerPaymentDto | null> {
    const existing = await db.customerPayment.findUnique({
      where: { clientMutationId: dto.clientMutationId },
    });
    if (!existing) return null;
    assertSameMutation(
      existing,
      user.id,
      existing.customerId === dto.customerId &&
        existing.amount === dto.amount &&
        existing.saleId === (dto.saleId ?? null),
      {
        code: ErrorCode.PAYMENT_ALREADY_RECORDED,
        message: `Règlement déjà enregistré : ${formatDA(existing.amount)} — vérifiez avant d’en refaire un`,
      },
    );
    return {
      id: existing.id,
      customerId: existing.customerId,
      saleId: existing.saleId,
      amount: existing.amount,
      paidAt: existing.paidAt,
      reversesPaymentId: existing.reversesPaymentId,
      balanceDue: await SalesService.customerDebt(db, existing.customerId),
    };
  }

  /// Cœur du règlement, dans la transaction de l'appelant (route en ligne ou
  /// handler de synchronisation). `actor` null : la sync écrit l'audit.
  /// `paidAt` : instant de l'appareil pour un règlement fait hors-ligne.
  async payInTx(
    tx: Prisma.TransactionClient,
    dto: CreateCustomerPaymentDto,
    user: AuthenticatedUser,
    actor: ActorContext | null,
    paidAt: Date = new Date(),
  ): Promise<CustomerPaymentDto> {
    await tx.$queryRaw`SELECT "id" FROM "Customer" WHERE "id" = ${dto.customerId}::uuid FOR UPDATE`;
    // Relu SOUS le verrou : le même règlement, envoyé en ligne (réponse perdue)
    // puis par la file, a pu se valider pendant l'attente — sans cette
    // relecture, la dette déjà réduite le ferait refuser à tort.
    const already = await this.replayPayment(tx, dto, user);
    if (already) return already;
    const customer = await tx.customer.findUnique({
      where: { id: dto.customerId },
    });
    if (!customer) throw CustomersService.notFound();

    const debt = await SalesService.customerDebt(tx, customer.id);
    if (dto.amount > debt) {
      throw new BusinessException(
        ErrorCode.VALIDATION_FAILED,
        `Règlement supérieur à la dette (${formatDA(debt)})`,
        HttpStatus.UNPROCESSABLE_ENTITY,
      );
    }
    if (dto.saleId) {
      const sale = await tx.sale.findUnique({ where: { id: dto.saleId } });
      if (
        !sale ||
        sale.customerId !== customer.id ||
        sale.status !== 'VALIDEE'
      ) {
        throw new BusinessException(
          ErrorCode.VALIDATION_FAILED,
          'saleId : vente introuvable pour ce client',
          HttpStatus.UNPROCESSABLE_ENTITY,
        );
      }
      const paidLater = await tx.customerPayment.aggregate({
        where: { saleId: sale.id },
        _sum: { amount: true },
      });
      const remaining =
        sale.totalTtc - sale.paidAmount - (paidLater._sum.amount ?? 0);
      if (dto.amount > remaining) {
        throw new BusinessException(
          ErrorCode.VALIDATION_FAILED,
          `Règlement supérieur au reste dû de la vente (${formatDA(remaining)})`,
          HttpStatus.UNPROCESSABLE_ENTITY,
        );
      }
    }

    const session = await CashSessionsService.lockOpenSession(tx, {
      userId: user.id,
    });
    if (!session) {
      throw new BusinessException(
        ErrorCode.CASH_SESSION_REQUIRED,
        'Ouvrez votre caisse avant d’encaisser un règlement',
        HttpStatus.UNPROCESSABLE_ENTITY,
      );
    }
    // Mêmes règles que la vente en espèces : les espèces restent dans la caisse
    // où elles sont entrées, jamais imputées à une autre (audit tranche B).
    if (dto.cashSessionId !== undefined && dto.cashSessionId !== session.id) {
      throw new BusinessException(
        ErrorCode.CASH_SESSION_CLOSED,
        'La caisse de ce règlement a été clôturée avant sa synchronisation : ' +
          'ses espèces ne peuvent pas entrer dans la caisse actuelle — voir l’administrateur',
        HttpStatus.CONFLICT,
      );
    }

    const payment = await tx.customerPayment.create({
      data: {
        id: dto.id,
        clientMutationId: dto.clientMutationId,
        customerId: customer.id,
        saleId: dto.saleId ?? null,
        userId: user.id,
        amount: dto.amount,
        method: 'ESPECES',
        note: dto.note ?? null,
        // Jamais avant l'ouverture de la caisse où entrent ses espèces.
        paidAt: paidAt < session.openedAt ? session.openedAt : paidAt,
      },
    });
    // Point d'entrée COMMUN des espèces (comme `withdraw` pour les sorties).
    await CashSessionsService.deposit(tx, session, {
      userId: user.id,
      amount: dto.amount,
      saleId: dto.saleId ?? undefined,
      // Rapprochement caisse ↔ règlement par l'id du règlement.
      note: `Règlement ${payment.id} — ${customer.name}`,
    });
    if (actor) {
      await writeAudit(tx, actor, {
        action: 'CREATE',
        entityType: 'CustomerPayment',
        entityId: payment.id,
        newValue: {
          customerId: customer.id,
          amount: dto.amount,
          saleId: dto.saleId ?? null,
        },
      });
    }
    return {
      id: payment.id,
      customerId: customer.id,
      saleId: payment.saleId,
      amount: payment.amount,
      paidAt: payment.paidAt,
      reversesPaymentId: null,
      balanceDue: debt - dto.amount,
    };
  }

  /// Historique des règlements d'un client, contre-passations comprises.
  async payments(
    customerId: string,
    query: PaginationQueryDto,
  ): Promise<PaymentHistoryDto> {
    const where = { customerId };
    const [rows, total] = await Promise.all([
      this.prisma.customerPayment.findMany({
        where,
        include: { reversedBy: { select: { id: true } } },
        skip: (query.page - 1) * query.limit,
        take: query.limit,
        orderBy: [
          parseSort(query.sort, PAYMENT_SORT_FIELDS, { paidAt: 'desc' }),
          { id: 'desc' },
        ],
      }),
      this.prisma.customerPayment.count({ where }),
    ]);
    return {
      data: rows.map((p) => ({
        id: p.id,
        amount: p.amount,
        method: p.method,
        fromCash: true, // règlement client = espèces en caisse (décision 2026-09-15)
        paidAt: p.paidAt,
        userId: p.userId,
        saleId: p.saleId,
        note: p.note,
        reversesPaymentId: p.reversesPaymentId,
        reversedById: p.reversedBy?.id ?? null,
      })),
      meta: { page: query.page, limit: query.limit, total },
    };
  }

  /// Contre-passation (ADMIN) d'un règlement saisi par erreur : écriture
  /// OPPOSÉE (la dette revient), espèces RENDUES depuis la caisse ouverte de
  /// l'admin — jamais plus que le tiroir (garde commun `withdraw`). Le règlement
  /// d'origine reste intact (règle 7) et ne s'annule qu'une fois.
  async reverse(
    id: string,
    dto: ReversePaymentDto,
    user: AuthenticatedUser,
    actor: ActorContext,
  ): Promise<CustomerPaymentDto> {
    const replay = async () => {
      const existing = await this.prisma.customerPayment.findUnique({
        where: { clientMutationId: dto.clientMutationId },
      });
      if (!existing) return null;
      assertSameMutation(existing, user.id, existing.reversesPaymentId === id, {
        code: ErrorCode.PAYMENT_ALREADY_RECORDED,
        message: 'Cette clé a déjà servi à une autre opération',
      });
      return CustomersService.paymentDto(
        existing,
        await SalesService.customerDebt(this.prisma, existing.customerId),
      );
    };
    return runOnce(replay, () =>
      this.prisma.$transaction(async (tx) => {
        await tx.$queryRaw`SELECT "id" FROM "CustomerPayment" WHERE "id" = ${id}::uuid FOR UPDATE`;
        const original = await tx.customerPayment.findUnique({
          where: { id },
          include: { reversedBy: { select: { id: true } } },
        });
        if (!original) {
          throw new BusinessException(
            ErrorCode.NOT_FOUND,
            'Règlement introuvable',
            HttpStatus.NOT_FOUND,
          );
        }
        if (original.reversesPaymentId || original.reversedBy) {
          throw new BusinessException(
            ErrorCode.INVALID_STATE_TRANSITION,
            original.reversesPaymentId
              ? 'Une contre-passation ne se contre-passe pas'
              : 'Ce règlement a déjà été contre-passé',
            HttpStatus.CONFLICT,
          );
        }
        await tx.$queryRaw`SELECT "id" FROM "Customer" WHERE "id" = ${original.customerId}::uuid FOR UPDATE`;
        const session = await CashSessionsService.lockOpenSession(tx, {
          userId: user.id,
        });
        if (!session) {
          throw new BusinessException(
            ErrorCode.CASH_SESSION_REQUIRED,
            'Ouvrez votre caisse : les espèces du règlement sont rendues au client',
            HttpStatus.UNPROCESSABLE_ENTITY,
          );
        }
        const reversal = await tx.customerPayment.create({
          data: {
            clientMutationId: dto.clientMutationId,
            customerId: original.customerId,
            saleId: original.saleId,
            userId: user.id,
            amount: -original.amount,
            method: original.method,
            note: dto.reason,
            reversesPaymentId: original.id,
          },
        });
        await CashSessionsService.withdraw(tx, session, {
          userId: user.id,
          amount: original.amount,
          saleId: original.saleId ?? undefined,
          note: `Contre-passation du règlement ${original.id}`,
        });
        await writeAudit(tx, actor, {
          action: 'CANCEL',
          entityType: 'CustomerPayment',
          entityId: original.id,
          oldValue: { amount: original.amount },
          newValue: { reversalId: reversal.id, reason: dto.reason },
        });
        return CustomersService.paymentDto(
          reversal,
          await SalesService.customerDebt(tx, original.customerId),
        );
      }),
    );
  }

  private static paymentDto(
    payment: {
      id: string;
      customerId: string;
      saleId: string | null;
      amount: number;
      paidAt: Date;
      reversesPaymentId: string | null;
    },
    balanceDue: number,
  ): CustomerPaymentDto {
    return {
      id: payment.id,
      customerId: payment.customerId,
      saleId: payment.saleId,
      amount: payment.amount,
      paidAt: payment.paidAt,
      reversesPaymentId: payment.reversesPaymentId,
      balanceDue,
    };
  }

  /// Tarif et plafond de crédit : conditions commerciales fixées par l'ADMIN
  /// seul (règles fermes de docs/permissions.md). Le vendeur crée la fiche.
  private static assertCommercialTermsAllowed(
    dto: { priceTierId?: string | null; creditLimit?: number },
    user: AuthenticatedUser,
  ) {
    const touches =
      dto.priceTierId !== undefined || dto.creditLimit !== undefined;
    if (touches && !user.permissions.includes(PERMISSIONS.PRICE_MANAGE)) {
      throw new BusinessException(
        ErrorCode.FORBIDDEN_PERMISSION,
        'Tarif et plafond de crédit sont fixés par l’administrateur',
        HttpStatus.FORBIDDEN,
      );
    }
  }

  private static async assertTier(tx: Db, id: string) {
    const tier = await tx.priceTier.findFirst({
      where: { id, isActive: true },
    });
    if (!tier) {
      throw new BusinessException(
        ErrorCode.VALIDATION_FAILED,
        'priceTierId : tarif introuvable ou inactif',
        HttpStatus.UNPROCESSABLE_ENTITY,
      );
    }
  }

  private static notFound() {
    return new BusinessException(
      ErrorCode.NOT_FOUND,
      'Client introuvable',
      HttpStatus.NOT_FOUND,
    );
  }

  private async toDto(
    db: Db | PrismaService,
    customer: Customer,
  ): Promise<CustomerDto> {
    const debts = await SalesService.customerDebts(db, [customer.id]);
    const overdue = await SalesService.customerOverdue(
      db,
      [customer.id],
      debts,
    );
    return CustomersService.toDtoWith(
      customer,
      debts.get(customer.id) ?? 0,
      overdue.get(customer.id) ?? 0,
    );
  }

  private static toDtoWith(
    customer: Customer,
    balanceDue: number,
    overdueAmount: number,
  ): CustomerDto {
    return {
      id: customer.id,
      code: customer.code,
      name: customer.name,
      phone: customer.phone,
      email: customer.email,
      address: customer.address,
      notes: customer.notes,
      priceTierId: customer.priceTierId,
      creditLimit: customer.creditLimit,
      balanceDue,
      overdueAmount,
      isActive: customer.isActive,
    };
  }
}
