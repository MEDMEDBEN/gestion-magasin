import { HttpStatus, Injectable } from '@nestjs/common';
import { ActorContext, writeAudit } from '../audit/audit-writer';
import { AuthenticatedUser } from '../common/auth.decorators';
import { BusinessException } from '../common/business.exception';
import { ErrorCode } from '../common/error-codes';
import { assertSameMutation, runOnce } from '../common/idempotency';
import { Prisma, Supplier } from '../generated/prisma/client';
import { parseSort } from '../common/dto/pagination.dto';
import {
  PaymentHistoryDto,
  ReversePaymentDto,
} from '../common/dto/payment.dto';
import { PaginationQueryDto } from '../common/dto/pagination.dto';
import { PrismaService } from '../prisma/prisma.service';
import { formatDA } from '../common/pdf/pdf';
import { CashSessionsService } from '../sales/cash-sessions.service';
import {
  CreateSupplierDto,
  CreateSupplierPaymentDto,
  SupplierDto,
  SupplierListDto,
  SupplierExportQueryDto,
  SupplierListQueryDto,
  SupplierPaymentDto,
  SupplierProductPriceDto,
  SupplierStatsDto,
  UpdateSupplierDto,
} from './dto/supplier.dto';
import {
  assertExportable,
  collectAll,
  ExportDocument,
  section,
} from '../common/export/export';
import { localDate } from '../common/document-number';
import {
  PAYMENT_METHOD_LABEL,
  signedMinus,
  StatementEntry,
  statementDocument,
  statementFilename,
} from '../common/export/statement';

type Db = Prisma.TransactionClient;

/// Tris autorisés (liste blanche, CONVENTIONS.md).
const SUPPLIER_SORT_FIELDS = ['name', 'createdAt'] as const;
const PAYMENT_SORT_FIELDS = ['paidAt', 'amount'] as const;

@Injectable()
export class SuppliersService {
  constructor(private readonly prisma: PrismaService) {}

  /// Dette fournisseur (règle : jamais stockée, toujours recalculée) :
  /// reprise de l'existant + marchandise RÉELLEMENT reçue (TTC figé à la
  /// réception) − paiements. La commande seule n'endette pas : la dette naît à
  /// la réception (décision MEDMEDBEN 2026-09-16).
  /// Les RETOURS fournisseur (P1 bis n°21l) se retranchent du reçu : « Reçu »
  /// est NET des marchandises renvoyées.
  static async debt(db: Db | PrismaService, supplier: Supplier) {
    const [paid, received, returned] = await Promise.all([
      db.supplierPayment.aggregate({
        where: { supplierId: supplier.id },
        _sum: { amount: true },
      }),
      db.reception.aggregate({
        where: { supplierId: supplier.id },
        _sum: { totalTtc: true },
      }),
      db.supplierReturn.aggregate({
        where: { supplierId: supplier.id },
        _sum: { totalTtc: true },
      }),
    ]);
    const paidAmount = paid._sum.amount ?? 0;
    const receivedAmount =
      (received._sum.totalTtc ?? 0) - (returned._sum.totalTtc ?? 0);
    return {
      paidAmount,
      receivedAmount,
      balanceDue: supplier.openingBalance + receivedAmount - paidAmount,
    };
  }

  /// Export de la liste (spec §8quinquies) : les lignes de `findAll`, avec ses
  /// filtres. `debtOnly` en fait l'export des dettes fournisseurs.
  async exportDocument(query: SupplierExportQueryDto): Promise<ExportDocument> {
    const all = await collectAll((page, limit) =>
      this.findAll({ ...query, page, limit }),
    );
    // ponytail: la dette est filtrée APRÈS lecture (elle est recalculée, pas
    // stockée) ; au-delà de 10 000 fournisseurs, l'export des dettes est refusé même
    // s'il y a peu de débiteurs — passer le filtre en SQL si cela arrive.
    const rows = query.debtOnly ? all.filter((s) => s.balanceDue > 0) : all;
    return {
      title: query.debtOnly ? 'Dettes fournisseurs' : 'Fournisseurs',
      subtitle: query.debtOnly
        ? `${rows.length} fournisseur(s) à qui nous devons`
        : `${rows.length} fournisseur(s)`,
      filename: query.debtOnly ? 'dettes-fournisseurs' : 'fournisseurs',
      sections: [
        section({
          columns: [
            { header: 'Code', value: (s) => s.code },
            { header: 'Nom', value: (s) => s.name },
            { header: 'Contact', value: (s) => s.contactName },
            { header: 'Téléphone', value: (s) => s.phone },
            { header: 'E-mail', value: (s) => s.email },
            {
              header: 'Reprise',
              kind: 'money',
              value: (s) => s.openingBalance,
            },
            { header: 'Reçu', kind: 'money', value: (s) => s.receivedAmount },
            { header: 'Payé', kind: 'money', value: (s) => s.paidAmount },
            { header: 'Dette', kind: 'money', value: (s) => s.balanceDue },
          ],
          rows,
        }),
      ],
    };
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
    // Deux agrégats groupés pour toute la page (jamais une requête, ni un
    // chargement de lignes, par fournisseur).
    const ids = rows.map((r) => r.id);
    const [paid, received, returned] = await Promise.all([
      this.prisma.supplierPayment.groupBy({
        by: ['supplierId'],
        where: { supplierId: { in: ids } },
        _sum: { amount: true },
      }),
      this.prisma.reception.groupBy({
        by: ['supplierId'],
        where: { supplierId: { in: ids } },
        _sum: { totalTtc: true },
      }),
      this.prisma.supplierReturn.groupBy({
        by: ['supplierId'],
        where: { supplierId: { in: ids } },
        _sum: { totalTtc: true },
      }),
    ]);
    const paidBy = new Map(paid.map((p) => [p.supplierId, p._sum.amount ?? 0]));
    // Reçu NET des retours fournisseur (même règle que `debt`).
    const receivedBy = new Map(
      received.map((r) => [r.supplierId, r._sum.totalTtc ?? 0]),
    );
    for (const r of returned) {
      receivedBy.set(
        r.supplierId,
        (receivedBy.get(r.supplierId) ?? 0) - (r._sum.totalTtc ?? 0),
      );
    }
    const data = rows.map((row) =>
      SuppliersService.toDtoWith(
        row,
        paidBy.get(row.id) ?? 0,
        receivedBy.get(row.id) ?? 0,
      ),
    );
    return { data, meta: { page: query.page, limit: query.limit, total } };
  }

  async findOne(id: string): Promise<SupplierDto> {
    const supplier = await this.prisma.supplier.findUnique({ where: { id } });
    if (!supplier) throw SuppliersService.notFound();
    return this.toDto(this.prisma, supplier);
  }

  /// Relevé de compte (P1 bis n°21n) : reprise de l'existant, réceptions,
  /// retours, paiements et contre-passations — les MÊMES composantes que
  /// `debt` : le dernier solde EST la dette envers ce fournisseur.
  async statement(id: string): Promise<ExportDocument> {
    const supplier = await this.prisma.supplier.findUnique({ where: { id } });
    if (!supplier) throw SuppliersService.notFound();
    // Taille vérifiée AVANT de tout charger en mémoire.
    const mine = { supplierId: id };
    assertExportable(
      (
        await Promise.all([
          this.prisma.reception.count({ where: mine }),
          this.prisma.supplierReturn.count({ where: mine }),
          this.prisma.supplierPayment.count({ where: mine }),
        ])
      ).reduce((a, b) => a + b, 0),
    );
    const [receptions, returns, payments] = await Promise.all([
      this.prisma.reception.findMany({
        where: { supplierId: id },
        select: { receivedAt: true, number: true, totalTtc: true },
      }),
      this.prisma.supplierReturn.findMany({
        where: { supplierId: id },
        select: { createdAt: true, number: true, totalTtc: true },
      }),
      this.prisma.supplierPayment.findMany({
        where: { supplierId: id },
        select: {
          paidAt: true,
          amount: true,
          method: true,
          note: true,
          reversesPaymentId: true,
        },
      }),
    ]);
    const entries: StatementEntry[] = [
      ...(supplier.openingBalance
        ? [
            {
              at: supplier.createdAt,
              piece: null,
              label: 'Reprise de l’existant',
              ...signedMinus(-supplier.openingBalance),
            },
          ]
        : []),
      ...receptions.map((r) => ({
        at: r.receivedAt,
        piece: r.number,
        label: 'Réception',
        plus: r.totalTtc,
        minus: 0,
      })),
      ...returns.map((r) => ({
        at: r.createdAt,
        piece: r.number,
        label: 'Retour de marchandise',
        plus: 0,
        minus: r.totalTtc,
      })),
      ...payments.map((p) => ({
        at: p.paidAt,
        piece: null,
        label: p.reversesPaymentId
          ? `Contre-passation${p.note ? ` : ${p.note}` : ''}`
          : `Paiement (${PAYMENT_METHOD_LABEL[p.method]})`,
        ...signedMinus(p.amount),
      })),
    ];
    return statementDocument({
      title: `Relevé de compte — ${supplier.name}`,
      subtitle: 'Solde : ce que le magasin doit au fournisseur',
      filename: statementFilename(
        'fournisseur',
        supplier.name,
        localDate(new Date()),
      ),
      plusHeader: 'Crédit',
      minusHeader: 'Débit',
      entries,
    });
  }

  /// Indicateurs (P1 bis n°21m) : produits fournis, livraisons à l'heure,
  /// évolution des prix d'achat par produit (réceptions, jamais les commandes :
  /// seul le reçu fait foi, comme pour la dette).
  async stats(id: string): Promise<SupplierStatsDto> {
    if (!(await this.prisma.supplier.findUnique({ where: { id } }))) {
      throw SuppliersService.notFound();
    }
    // ponytail: toutes les lignes de réception du fournisseur, lues en mémoire
    // (quelques milliers au plus pour un magasin) ; agréger en SQL au-delà.
    // `receivedAt` : l'heure réelle de la réception (celle de l'appareil hors
    // ligne), la même référence que le « dernier prix » de la règle 5 — jamais
    // l'heure de synchronisation.
    const [lines, dated] = await Promise.all([
      this.prisma.receptionLine.findMany({
        where: { reception: { supplierId: id } },
        orderBy: [{ reception: { receivedAt: 'desc' } }, { id: 'desc' }],
        select: {
          productId: true,
          unitPriceHt: true,
          reception: { select: { id: true, receivedAt: true } },
          product: { select: { name: true, sku: true } },
        },
      }),
      this.prisma.reception.findMany({
        where: {
          supplierId: id,
          purchaseOrder: { expectedDate: { not: null } },
        },
        select: {
          receivedAt: true,
          purchaseOrder: { select: { expectedDate: true } },
        },
      }),
    ]);
    const prices = new Map<string, SupplierProductPriceDto>();
    // Dernière réception vue par produit : un produit sur deux lignes d'un
    // même bon compte UNE réception (et son prix n'est pas « le précédent »).
    const lastSeen = new Map<string, string>();
    for (const line of lines) {
      const seen = prices.get(line.productId);
      if (!seen) {
        prices.set(line.productId, {
          productId: line.productId,
          name: line.product.name,
          sku: line.product.sku,
          receptions: 1,
          firstPriceHt: line.unitPriceHt,
          previousPriceHt: null,
          lastPriceHt: line.unitPriceHt,
          lastReceivedAt: line.reception.receivedAt,
        });
        lastSeen.set(line.productId, line.reception.id);
        continue;
      }
      if (lastSeen.get(line.productId) === line.reception.id) continue;
      lastSeen.set(line.productId, line.reception.id);
      // Du plus récent au plus ancien : la 2e réception est la précédente, la
      // dernière lue est la première.
      if (seen.receptions === 1) seen.previousPriceHt = line.unitPriceHt;
      seen.firstPriceHt = line.unitPriceHt;
      seen.receptions++;
    }
    // Date prévue : un jour (AAAA-MM-JJ, la date prévue ACTUELLE de la
    // commande) ; à l'heure = reçu ce jour-là au plus tard, heure d'Alger.
    const onTime = dated.filter(
      (r) =>
        localDate(r.receivedAt) <=
        r.purchaseOrder!.expectedDate!.toISOString().slice(0, 10),
    ).length;
    return {
      productCount: prices.size,
      deliveriesWithDate: dated.length,
      deliveriesOnTime: onTime,
      prices: [...prices.values()].slice(0, 100),
    };
  }

  async create(
    dto: CreateSupplierDto,
    actor: ActorContext,
  ): Promise<SupplierDto> {
    return this.prisma.$transaction((tx) => this.createInTx(tx, dto, actor));
  }

  /// Cœur de la création, dans la transaction de l'appelant (route, import).
  async createInTx(
    tx: Prisma.TransactionClient,
    dto: CreateSupplierDto,
    actor: ActorContext,
  ): Promise<SupplierDto> {
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
      // « Supprimer » = retirer des listes (isActive), jamais effacer achats ni
      // paiements (règle 7) ; refusé tant que le solde n'est pas nul : ce
      // qu'on doit encore au fournisseur ne disparaît pas (2026-10-06).
      if (dto.isActive === false && before.isActive) {
        // Une commande en cours ne pourrait plus être reçue (la réception
        // exige un fournisseur actif) : la clôturer ou l'annuler d'abord.
        const pending = await tx.purchaseOrder.count({
          where: {
            supplierId: id,
            status: { notIn: ['RECUE', 'CLOTUREE', 'ANNULEE'] },
          },
        });
        if (pending > 0) {
          throw new BusinessException(
            ErrorCode.INVALID_STATE_TRANSITION,
            `${before.name} a encore ${pending} commande(s) en cours : clôturez-les ou annulez-les avant de le supprimer`,
            HttpStatus.CONFLICT,
          );
        }
        const { balanceDue } = await SuppliersService.debt(tx, before);
        if (balanceDue !== 0) {
          throw new BusinessException(
            ErrorCode.INVALID_STATE_TRANSITION,
            balanceDue > 0
              ? `Il reste ${formatDA(balanceDue)} à payer à ${before.name} : réglez-le avant de le supprimer`
              : `${before.name} vous doit ${formatDA(-balanceDue)} (trop-payé) : soldez-le avant de le supprimer`,
            HttpStatus.CONFLICT,
          );
        }
      }
      if (dto.openingBalance !== undefined) {
        // La reprise révisée ne doit pas rendre la dette négative : ce qui est
        // déjà payé, moins la marchandise reçue depuis, reste un plancher.
        const { paidAmount, receivedAmount } = await SuppliersService.debt(
          tx,
          before,
        );
        const floor = Math.max(0, paidAmount - receivedAmount);
        if (dto.openingBalance < floor) {
          throw new BusinessException(
            ErrorCode.VALIDATION_FAILED,
            `Déjà payé ${formatDA(paidAmount)} à ce fournisseur (dont ${formatDA(receivedAmount)} de marchandise reçue) : la reprise ne peut pas descendre sous ${formatDA(floor)}`,
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
            `Paiement supérieur au reste dû (${formatDA(balanceDue)})`,
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

  async payments(
    supplierId: string,
    query: PaginationQueryDto,
  ): Promise<PaymentHistoryDto> {
    const where = { supplierId };
    const [rows, total] = await Promise.all([
      this.prisma.supplierPayment.findMany({
        where,
        include: { reversedBy: { select: { id: true } } },
        skip: (query.page - 1) * query.limit,
        take: query.limit,
        orderBy: [
          parseSort(query.sort, PAYMENT_SORT_FIELDS, { paidAt: 'desc' }),
          { id: 'desc' },
        ],
      }),
      this.prisma.supplierPayment.count({ where }),
    ]);
    return {
      data: rows.map((p) => ({
        id: p.id,
        amount: p.amount,
        method: p.method,
        fromCash: p.cashSessionId !== null,
        paidAt: p.paidAt,
        userId: p.userId,
        saleId: null,
        note: p.note,
        reversesPaymentId: p.reversesPaymentId,
        reversedById: p.reversedBy?.id ?? null,
      })),
      meta: { page: query.page, limit: query.limit, total },
    };
  }

  /// Contre-passation (ADMIN) : écriture OPPOSÉE, la dette revient. Paiement
  /// sorti de la caisse → les espèces y RENTRENT (caisse ouverte de l'admin) ;
  /// payé hors caisse → la caisse n'est pas touchée. Jamais de suppression.
  async reverse(
    id: string,
    dto: ReversePaymentDto,
    user: AuthenticatedUser,
    actor: ActorContext,
  ): Promise<SupplierPaymentDto> {
    const replay = async () => {
      const existing = await this.prisma.supplierPayment.findUnique({
        where: { clientMutationId: dto.clientMutationId },
      });
      if (!existing) return null;
      assertSameMutation(existing, user.id, existing.reversesPaymentId === id, {
        code: ErrorCode.PAYMENT_ALREADY_RECORDED,
        message: 'Cette clé a déjà servi à une autre opération',
      });
      const supplier = await this.prisma.supplier.findUniqueOrThrow({
        where: { id: existing.supplierId },
      });
      const { balanceDue } = await SuppliersService.debt(this.prisma, supplier);
      return SuppliersService.paymentDto(existing, balanceDue);
    };
    return runOnce(replay, () =>
      this.prisma.$transaction(async (tx) => {
        await tx.$queryRaw`SELECT "id" FROM "SupplierPayment" WHERE "id" = ${id}::uuid FOR UPDATE`;
        const original = await tx.supplierPayment.findUnique({
          where: { id },
          include: { reversedBy: { select: { id: true } } },
        });
        if (!original) {
          throw new BusinessException(
            ErrorCode.NOT_FOUND,
            'Paiement introuvable',
            HttpStatus.NOT_FOUND,
          );
        }
        if (original.reversesPaymentId || original.reversedBy) {
          throw new BusinessException(
            ErrorCode.INVALID_STATE_TRANSITION,
            original.reversesPaymentId
              ? 'Une contre-passation ne se contre-passe pas'
              : 'Ce paiement a déjà été contre-passé',
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
            'Paiement par chèque : contre-passation impossible depuis le retrait des chèques',
            HttpStatus.CONFLICT,
          );
        }
        await tx.$queryRaw`SELECT "id" FROM "Supplier" WHERE "id" = ${original.supplierId}::uuid FOR UPDATE`;
        const session = original.cashSessionId
          ? await CashSessionsService.lockOpenSession(tx, { userId: user.id })
          : null;
        if (original.cashSessionId && !session) {
          throw new BusinessException(
            ErrorCode.CASH_SESSION_REQUIRED,
            'Ouvrez votre caisse : les espèces du paiement y sont remises',
            HttpStatus.UNPROCESSABLE_ENTITY,
          );
        }
        const reversal = await tx.supplierPayment.create({
          data: {
            clientMutationId: dto.clientMutationId,
            supplierId: original.supplierId,
            userId: user.id,
            cashSessionId: session?.id ?? null,
            amount: -original.amount,
            method: original.method,
            note: dto.reason,
            reversesPaymentId: original.id,
          },
        });
        if (session) {
          await CashSessionsService.deposit(tx, session, {
            userId: user.id,
            amount: original.amount,
            note: `Contre-passation du paiement fournisseur ${original.id}`,
          });
        }
        await writeAudit(tx, actor, {
          action: 'CANCEL',
          entityType: 'SupplierPayment',
          entityId: original.id,
          oldValue: { amount: original.amount },
          newValue: { reversalId: reversal.id, reason: dto.reason },
        });
        const supplier = await tx.supplier.findUniqueOrThrow({
          where: { id: original.supplierId },
        });
        const { balanceDue } = await SuppliersService.debt(tx, supplier);
        return SuppliersService.paymentDto(reversal, balanceDue);
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
      reversesPaymentId: string | null;
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
      reversesPaymentId: payment.reversesPaymentId,
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
    const { paidAmount, receivedAmount } = await SuppliersService.debt(
      db,
      supplier,
    );
    return SuppliersService.toDtoWith(supplier, paidAmount, receivedAmount);
  }

  private static toDtoWith(
    supplier: Supplier,
    paidAmount: number,
    receivedAmount: number,
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
      receivedAmount,
      balanceDue: supplier.openingBalance + receivedAmount - paidAmount,
      isActive: supplier.isActive,
    };
  }
}
