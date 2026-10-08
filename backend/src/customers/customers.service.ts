import { HttpStatus, Injectable } from '@nestjs/common';
import { ActorContext, writeAudit } from '../audit/audit-writer';
import { AuthenticatedUser, RoleCode } from '../common/auth.decorators';
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
import { SaleReturnsService } from '../sales/sale-returns.service';
import { SalesService } from '../sales/sales.service';
import {
  CreateCustomerDto,
  CustomerDto,
  CustomerListDto,
  CustomerExportQueryDto,
  CustomerListQueryDto,
  CustomerPaymentDto,
  CreateCustomerPaymentDto,
  UpdateCustomerDto,
} from './dto/customer.dto';
import {
  assertExportable,
  collectAll,
  ExportDocument,
  section,
} from '../common/export/export';
import {
  PAYMENT_METHOD_LABEL,
  signedMinus,
  StatementEntry,
  statementDocument,
  statementFilename,
} from '../common/export/statement';
import { localDate } from '../common/document-number';

type Db = Prisma.TransactionClient;

/// Tris autorisés (liste blanche, CONVENTIONS.md).
const CUSTOMER_SORT_FIELDS = ['name', 'createdAt'] as const;
const PAYMENT_SORT_FIELDS = ['paidAt', 'amount'] as const;

@Injectable()
export class CustomersService {
  constructor(private readonly prisma: PrismaService) {}

  /// Relevé de compte (P1 bis n°21n) : ventes validées (TTC dû, payé
  /// comptant), règlements, avoirs et contre-passations — les MÊMES composantes
  /// que `SalesService.customerAccounts` : le dernier solde EST la dette. Un
  /// retour remboursé en espèces n'y figure pas (rendu et remboursé : net nul).
  async statement(id: string): Promise<ExportDocument> {
    const customer = await this.prisma.customer.findUnique({ where: { id } });
    if (!customer) throw CustomersService.notFound();
    // Taille vérifiée AVANT de tout charger en mémoire.
    const saleWhere = { customerId: id, status: 'VALIDEE' as const };
    assertExportable(
      (
        await Promise.all([
          this.prisma.sale.count({ where: saleWhere }),
          this.prisma.customerPayment.count({ where: { customerId: id } }),
        ])
      ).reduce((a, b) => a + b, 0),
    );
    const [sales, payments] = await Promise.all([
      this.prisma.sale.findMany({
        where: saleWhere,
        select: {
          soldAt: true,
          number: true,
          invoiceNumber: true,
          totalTtc: true,
          paidAmount: true,
        },
      }),
      this.prisma.customerPayment.findMany({
        where: { customerId: id },
        select: {
          paidAt: true,
          amount: true,
          method: true,
          note: true,
          saleReturnId: true,
          reversesPaymentId: true,
        },
      }),
    ]);
    const entries: StatementEntry[] = [
      ...sales.map((s) => ({
        at: s.soldAt,
        piece: s.invoiceNumber ?? s.number,
        label:
          s.paidAmount > 0
            ? `Vente (payé comptant ${formatDA(s.paidAmount)})`
            : 'Vente à crédit',
        plus: s.totalTtc,
        minus: s.paidAmount,
      })),
      ...payments.map((p) => ({
        at: p.paidAt,
        piece: null,
        label: p.saleReturnId
          ? (p.note ?? 'Avoir')
          : p.reversesPaymentId
            ? `Contre-passation${p.note ? ` : ${p.note}` : ''}`
            : `Règlement (${PAYMENT_METHOD_LABEL[p.method]})`,
        ...signedMinus(p.amount),
      })),
    ];
    return statementDocument({
      title: `Relevé de compte — ${customer.name}`,
      subtitle: 'Solde : ce que le client doit au magasin',
      filename: statementFilename(
        'client',
        customer.name,
        localDate(new Date()),
      ),
      plusHeader: 'Débit',
      minusHeader: 'Crédit',
      entries,
    });
  }

  /// Export de la liste (spec §8quinquies) : les lignes de `findAll`, avec ses
  /// filtres. `debtOnly` en fait l'export des dettes clients.
  async exportDocument(query: CustomerExportQueryDto): Promise<ExportDocument> {
    const all = await collectAll((page, limit) =>
      this.findAll({ ...query, page, limit }),
    );
    // ponytail: la dette est filtrée APRÈS lecture (elle est recalculée, pas
    // stockée) ; au-delà de 10 000 clients, l'export des dettes est refusé même
    // s'il y a peu de débiteurs — passer le filtre en SQL si cela arrive.
    const rows = query.debtOnly ? all.filter((c) => c.balanceDue > 0) : all;
    return {
      title: query.debtOnly ? 'Dettes clients' : 'Clients',
      subtitle: query.debtOnly
        ? `${rows.length} client(s) avec une dette`
        : `${rows.length} client(s)`,
      filename: query.debtOnly ? 'dettes-clients' : 'clients',
      sections: [
        section({
          columns: [
            { header: 'Code', value: (c) => c.code },
            { header: 'Nom', value: (c) => c.name },
            { header: 'Téléphone', value: (c) => c.phone },
            { header: 'E-mail', value: (c) => c.email },
            { header: 'Adresse', value: (c) => c.address },
            {
              header: 'Plafond de crédit',
              kind: 'money',
              value: (c) => c.creditLimit,
            },
            { header: 'Dette', kind: 'money', value: (c) => c.balanceDue },
            {
              header: 'Dont en retard',
              kind: 'money',
              value: (c) => c.overdueAmount,
            },
          ],
          rows,
        }),
      ],
    };
  }

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
    const accounts = await SalesService.customerAccounts(this.prisma, ids);
    const overdue = await SalesService.customerOverdue(
      this.prisma,
      ids,
      SalesService.balances(accounts),
    );
    const data = rows.map((row) =>
      CustomersService.toDtoWith(
        row,
        accounts.get(row.id)!,
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
    return this.prisma.$transaction((tx) => this.createInTx(tx, dto, actor));
  }

  /// Cœur de la création, dans la transaction de l'appelant (route, import).
  /// Les conditions commerciales sont vérifiées par l'APPELANT (droits).
  async createInTx(
    tx: Prisma.TransactionClient,
    dto: CreateCustomerDto,
    actor: ActorContext,
  ): Promise<CustomerDto> {
    if (dto.priceTierId) await CustomersService.assertTier(tx, dto.priceTierId);
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
      if (dto.isActive !== undefined && dto.isActive !== before.isActive) {
        await CustomersService.assertCanChangeActive(tx, before, dto, user);
      }
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
    // Verrous Vente → Client, l'ordre des retours et de l'annulation : le
    // règlement référence la vente (clé étrangère) ; dans l'ordre inverse, un
    // retour simultané sur la même vente pourrait s'interbloquer avec lui.
    if (dto.saleId) {
      await tx.$queryRaw`SELECT "id" FROM "Sale" WHERE "id" = ${dto.saleId}::uuid FOR UPDATE`;
    }
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
        // Règlement client = espèces en caisse (décision 2026-09-15), sauf
        // l'avoir d'un retour : une écriture, aucune espèce.
        fromCash: p.method === 'ESPECES' && !p.saleReturnId,
        paidAt: p.paidAt,
        userId: p.userId,
        saleId: p.saleId,
        note: p.note,
        reversesPaymentId: p.reversesPaymentId,
        reversedById: p.reversedBy?.id ?? null,
        saleReturnId: p.saleReturnId,
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
        // Un avoir (retour client déduit de la dette) n'est pas un
        // encaissement : le contre-passer effacerait le retour de la dette.
        if (original.saleReturnId) {
          throw new BusinessException(
            ErrorCode.INVALID_STATE_TRANSITION,
            'Un avoir de retour ne se contre-passe pas',
            HttpStatus.CONFLICT,
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
        // Ancien règlement par chèque (fonctionnalité retirée le 2026-10-05,
        // données gardées) : il n'est jamais entré dans une caisse, et s'il est
        // encaissé l'argent est en banque. Le contre-passer ici fausserait la
        // caisse ou ferait revenir une dette payée : refusé (audits 2026-10-05).
        if (original.chequeStatus !== null) {
          throw new BusinessException(
            ErrorCode.INVALID_STATE_TRANSITION,
            'Règlement par chèque : contre-passation impossible depuis le retrait des chèques',
            HttpStatus.CONFLICT,
          );
        }
        // Verrous Vente → Client, l'ordre des retours et de l'annulation.
        if (original.saleId) {
          await tx.$queryRaw`SELECT "id" FROM "Sale" WHERE "id" = ${original.saleId}::uuid FOR UPDATE`;
        }
        await tx.$queryRaw`SELECT "id" FROM "Customer" WHERE "id" = ${original.customerId}::uuid FOR UPDATE`;
        // Des articles déjà remboursés sur cette vente : contre-passer ce
        // règlement ferait sortir des espèces que la vente n'a plus (le client
        // serait remboursé deux fois).
        if (original.saleId) {
          const sale = await tx.sale.findUniqueOrThrow({
            where: { id: original.saleId },
          });
          const { reallyPaid } = await SaleReturnsService.cashKept(tx, sale);
          if (reallyPaid - original.amount < 0) {
            throw new BusinessException(
              ErrorCode.INVALID_STATE_TRANSITION,
              'Des articles de cette vente ont déjà été remboursés : ce règlement ne se contre-passe plus',
              HttpStatus.CONFLICT,
            );
          }
        }
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

  /// « Supprimer » un client = le retirer des listes (isActive), jamais
  /// effacer ses ventes ni ses règlements (règle 7). ADMIN seul (le vendeur
  /// modifie une fiche, il ne la retire pas) ; refusé tant que le solde n'est
  /// pas nul — masquer une dette ferait perdre sa trace (2026-10-06).
  private static async assertCanChangeActive(
    tx: Db,
    before: { id: string; name: string },
    dto: { isActive?: boolean },
    user: AuthenticatedUser,
  ) {
    if (!user.roles.includes(RoleCode.ADMIN)) {
      throw new BusinessException(
        ErrorCode.FORBIDDEN_ROLE,
        'Seul l’administrateur retire ou réactive un client',
        HttpStatus.FORBIDDEN,
      );
    }
    if (dto.isActive !== false) return;
    // Verrou du client : un règlement simultané ne passe pas entre-temps.
    await tx.$queryRaw`SELECT "id" FROM "Customer" WHERE "id" = ${before.id}::uuid FOR UPDATE`;
    const debt = await SalesService.customerDebt(tx, before.id);
    if (debt !== 0) {
      throw new BusinessException(
        ErrorCode.INVALID_STATE_TRANSITION,
        debt > 0
          ? `${before.name} doit encore ${formatDA(debt)} : encaissez sa dette avant de le supprimer`
          : `${before.name} a un avoir de ${formatDA(-debt)} : soldez-le avant de le supprimer`,
        HttpStatus.CONFLICT,
      );
    }
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
    const accounts = await SalesService.customerAccounts(db, [customer.id]);
    const account = accounts.get(customer.id)!;
    const overdue = await SalesService.customerOverdue(
      db,
      [customer.id],
      SalesService.balances(accounts),
    );
    return CustomersService.toDtoWith(
      customer,
      account,
      overdue.get(customer.id) ?? 0,
    );
  }

  /// Ce qu'un compte voit d'une fiche client : total acheté et payé sont un
  /// CHIFFRE D'AFFAIRES — ADMIN seul (docs/permissions.md : ni le magasinier
  /// ni le vendeur, limité à SES ventes, ne lisent un CA). `null`, jamais 0.
  static forViewer(
    customer: CustomerDto,
    viewer: Pick<AuthenticatedUser, 'roles'>,
  ): CustomerDto {
    if (viewer.roles.includes(RoleCode.ADMIN)) return customer;
    return { ...customer, totalPurchased: null, totalPaid: null };
  }

  private static toDtoWith(
    customer: Customer,
    account: { purchased: number; balance: number },
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
      balanceDue: account.balance,
      overdueAmount,
      totalPurchased: account.purchased,
      totalPaid: account.purchased - account.balance,
      isActive: customer.isActive,
      isConfrere: customer.supplierId !== null,
    };
  }
}
