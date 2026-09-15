import { HttpStatus, Injectable } from '@nestjs/common';
import { ActorContext, writeAudit } from '../audit/audit-writer';
import { AuthenticatedUser } from '../common/auth.decorators';
import { BusinessException } from '../common/business.exception';
import { ErrorCode } from '../common/error-codes';
import { PERMISSIONS } from '../common/permissions';
import { Customer, Prisma } from '../generated/prisma/client';
import { PrismaService } from '../prisma/prisma.service';
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
        orderBy: [{ name: 'asc' }, { id: 'asc' }],
      }),
      this.prisma.customer.count({ where }),
    ]);
    const data: CustomerDto[] = [];
    for (const row of rows) data.push(await this.toDto(this.prisma, row));
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
    return this.prisma.$transaction(async (tx) => {
      await tx.$queryRaw`SELECT "id" FROM "Customer" WHERE "id" = ${dto.customerId}::uuid FOR UPDATE`;
      const customer = await tx.customer.findUnique({
        where: { id: dto.customerId },
      });
      if (!customer) throw CustomersService.notFound();

      const debt = await SalesService.customerDebt(tx, customer.id);
      if (dto.amount > debt) {
        throw new BusinessException(
          ErrorCode.VALIDATION_FAILED,
          `Règlement supérieur à la dette (${debt} centimes)`,
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
            `Règlement supérieur au reste dû de la vente (${remaining} centimes)`,
            HttpStatus.UNPROCESSABLE_ENTITY,
          );
        }
      }

      const session = await tx.cashSession.findFirst({
        where: { userId: user.id, status: 'OUVERTE' },
      });
      if (!session) {
        throw new BusinessException(
          ErrorCode.CASH_SESSION_REQUIRED,
          'Ouvrez votre caisse avant d’encaisser un règlement',
          HttpStatus.UNPROCESSABLE_ENTITY,
        );
      }

      const payment = await tx.customerPayment.create({
        data: {
          id: dto.id,
          customerId: customer.id,
          saleId: dto.saleId ?? null,
          userId: user.id,
          amount: dto.amount,
          method: 'ESPECES',
          note: dto.note ?? null,
        },
      });
      await tx.cashMovement.create({
        data: {
          cashSessionId: session.id,
          userId: user.id,
          type: 'ENTREE',
          amount: dto.amount,
          note: `Règlement client ${customer.name}`,
        },
      });
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
      return {
        id: payment.id,
        customerId: customer.id,
        saleId: payment.saleId,
        amount: payment.amount,
        paidAt: payment.paidAt,
        balanceDue: debt - dto.amount,
      };
    });
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
      balanceDue: await SalesService.customerDebt(db, customer.id),
      isActive: customer.isActive,
    };
  }
}
