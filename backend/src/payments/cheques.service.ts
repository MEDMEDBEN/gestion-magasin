import { HttpStatus, Injectable } from '@nestjs/common';
import { ActorContext, writeAudit } from '../audit/audit-writer';
import { AuthenticatedUser, RoleCode } from '../common/auth.decorators';
import { BusinessException } from '../common/business.exception';
import {
  ChequeDto,
  ChequeListQueryDto,
  ChequeStatusDto,
} from '../common/dto/payment.dto';
import { ErrorCode } from '../common/error-codes';
import { formatDA } from '../common/pdf/pdf';
import { Prisma } from '../generated/prisma/client';
import { NotificationsService } from '../notifications/notifications.service';
import { PrismaService } from '../prisma/prisma.service';

type Db = Prisma.TransactionClient;
export type ChequeKind = 'CLIENT' | 'FOURNISSEUR';

/// Suivi des chèques (P1 bis n°21n, décisions MEDMEDBEN 2026-09-28).
///
/// Un chèque est un règlement client (reçu) ou un paiement fournisseur (émis)
/// portant `chequeStatus`. Il ne passe JAMAIS par une caisse. La dette a bougé
/// dès la remise ; l'ADMIN statue ensuite :
/// - ENCAISSE : passé en banque, rien d'autre ne bouge ;
/// - REJETE : refusé par la banque → contre-passation (écriture opposée, règle
///   7), la dette revient ; alerte à l'admin et, pour un client, au vendeur
///   qui l'a reçu.
/// Une décision ne se prend qu'une fois : la même, renvoyée, rend l'état
/// actuel (idempotent) ; une autre est refusée (409).
@Injectable()
export class ChequesService {
  constructor(private readonly prisma: PrismaService) {}

  /// Portefeuille : les deux sens, du plus ancien au plus récent (les chèques à
  /// remettre en banque d'abord). Les contre-passations n'en font pas partie ;
  /// un chèque annulé par contre-passation n'est plus « en portefeuille ».
  async list(query: ChequeListQueryDto): Promise<ChequeDto[]> {
    // Un chèque contre-passé à la main (erreur de saisie) n'est plus un
    // chèque à suivre ; un chèque REJETÉ l'est par définition, il reste listé.
    const where = {
      chequeStatus: query.status ?? { not: null },
      OR: [{ chequeStatus: 'REJETE' as const }, { reversedBy: null }],
    };
    // En portefeuille : les plus anciens d'abord (à remettre en banque) ;
    // sinon les plus récents (l'historique ne fait que grossir).
    const order =
      query.status === 'EN_PORTEFEUILLE' ? ('asc' as const) : ('desc' as const);
    // ponytail: 500 par sens ; paginer si le portefeuille
    // d'un magasin dépasse ce volume.
    const [received, issued] = await Promise.all([
      this.prisma.customerPayment.findMany({
        where,
        include: { customer: { select: { name: true } } },
        orderBy: { paidAt: order },
        take: 500,
      }),
      this.prisma.supplierPayment.findMany({
        where,
        include: { supplier: { select: { name: true } } },
        orderBy: { paidAt: order },
        take: 500,
      }),
    ]);
    return [
      ...received.map((p) =>
        ChequesService.toDto('CLIENT', p, p.customerId, p.customer.name),
      ),
      ...issued.map((p) =>
        ChequesService.toDto('FOURNISSEUR', p, p.supplierId, p.supplier.name),
      ),
    ].sort((a, b) =>
      order === 'asc'
        ? a.paidAt.getTime() - b.paidAt.getTime()
        : b.paidAt.getTime() - a.paidAt.getTime(),
    );
  }

  async setStatus(
    kind: ChequeKind,
    id: string,
    dto: ChequeStatusDto,
    user: AuthenticatedUser,
    actor: ActorContext,
  ): Promise<ChequeDto> {
    return this.prisma.$transaction(async (tx) => {
      const table = kind === 'CLIENT' ? 'CustomerPayment' : 'SupplierPayment';
      await tx.$queryRaw`SELECT "id" FROM ${Prisma.raw(`"${table}"`)} WHERE "id" = ${id}::uuid FOR UPDATE`;
      const cheque = await ChequesService.load(tx, kind, id);
      if (!cheque || cheque.chequeStatus === null) {
        throw new BusinessException(
          ErrorCode.NOT_FOUND,
          'Chèque introuvable',
          HttpStatus.NOT_FOUND,
        );
      }
      // Renvoi de la même décision : l'état actuel, sans double effet.
      if (cheque.chequeStatus === dto.status)
        return ChequesService.dtoOf(kind, cheque);
      if (cheque.chequeStatus !== 'EN_PORTEFEUILLE' || cheque.reversedBy) {
        throw new BusinessException(
          ErrorCode.INVALID_STATE_TRANSITION,
          cheque.reversedBy
            ? 'Ce règlement a été contre-passé : le chèque ne se traite plus'
            : 'Ce chèque a déjà été traité',
          HttpStatus.CONFLICT,
        );
      }
      const now = new Date();
      const status = {
        chequeStatus: dto.status,
        chequeStatusAt: now,
        chequeStatusById: user.id,
      };
      if (dto.status === 'REJETE') {
        await ChequesService.reject(tx, kind, cheque, dto, user);
      }
      const updated =
        kind === 'CLIENT'
          ? await tx.customerPayment.update({ where: { id }, data: status })
          : await tx.supplierPayment.update({ where: { id }, data: status });
      await writeAudit(tx, actor, {
        action: 'UPDATE',
        entityType: kind === 'CLIENT' ? 'CustomerPayment' : 'SupplierPayment',
        entityId: id,
        oldValue: { chequeStatus: 'EN_PORTEFEUILLE' },
        newValue: {
          chequeStatus: dto.status,
          number: cheque.chequeNumber,
          amount: cheque.amount,
          reason: dto.reason ?? null,
        },
      });
      return ChequesService.dtoOf(kind, { ...cheque, ...updated });
    });
  }

  /// Rejet : écriture opposée (la dette revient), jamais de caisse touchée.
  /// Verrous dans l'ordre des autres écritures : Vente → Client, ou Fournisseur.
  private static async reject(
    tx: Db,
    kind: ChequeKind,
    cheque: Loaded,
    dto: ChequeStatusDto,
    user: AuthenticatedUser,
  ) {
    const note = `Chèque n° ${cheque.chequeNumber} rejeté${dto.reason ? ` : ${dto.reason}` : ''}`;
    const alert = {
      type: 'CHEQUE_REJETE' as const,
      title: `Chèque rejeté — ${cheque.partyName}`,
      body: `${formatDA(cheque.amount)} (n° ${cheque.chequeNumber}, ${cheque.chequeBank}) : la dette revient.`,
      priority: 'HAUTE' as const,
      operationType:
        kind === 'CLIENT'
          ? ('CUSTOMER_PAYMENT' as const)
          : ('SUPPLIER_PAYMENT' as const),
      operationId: cheque.id,
    };
    if (kind === 'CLIENT') {
      if (cheque.saleId) {
        await tx.$queryRaw`SELECT "id" FROM "Sale" WHERE "id" = ${cheque.saleId}::uuid FOR UPDATE`;
      }
      await tx.$queryRaw`SELECT "id" FROM "Customer" WHERE "id" = ${cheque.partyId}::uuid FOR UPDATE`;
      await tx.customerPayment.create({
        data: {
          clientMutationId: dto.clientMutationId,
          customerId: cheque.partyId,
          saleId: cheque.saleId,
          userId: user.id,
          amount: -cheque.amount,
          method: 'CHEQUE',
          note,
          reversesPaymentId: cheque.id,
        },
      });
    } else {
      await tx.$queryRaw`SELECT "id" FROM "Supplier" WHERE "id" = ${cheque.partyId}::uuid FOR UPDATE`;
      await tx.supplierPayment.create({
        data: {
          clientMutationId: dto.clientMutationId,
          supplierId: cheque.partyId,
          userId: user.id,
          amount: -cheque.amount,
          method: 'CHEQUE',
          note,
          reversesPaymentId: cheque.id,
        },
      });
    }
    // Admins + (client) le vendeur qui l'a reçu — il doit rappeler son
    // client. UNE alerte chacun, jamais à celui qui statue.
    const admins = await tx.user.findMany({
      where: { roles: { some: { code: RoleCode.ADMIN } } },
      select: { id: true },
    });
    await NotificationsService.notifyUsers(
      tx,
      [
        ...admins.map((a) => a.id),
        ...(kind === 'CLIENT' ? [cheque.userId] : []),
      ].filter((id) => id !== user.id),
      alert,
    );
  }

  private static async load(
    tx: Db,
    kind: ChequeKind,
    id: string,
  ): Promise<Loaded | null> {
    if (kind === 'CLIENT') {
      const p = await tx.customerPayment.findUnique({
        where: { id },
        include: {
          customer: { select: { name: true } },
          reversedBy: { select: { id: true } },
        },
      });
      return p && { ...p, partyId: p.customerId, partyName: p.customer.name };
    }
    const p = await tx.supplierPayment.findUnique({
      where: { id },
      include: {
        supplier: { select: { name: true } },
        reversedBy: { select: { id: true } },
      },
    });
    return (
      p && {
        ...p,
        saleId: null,
        partyId: p.supplierId,
        partyName: p.supplier.name,
      }
    );
  }

  private static dtoOf(kind: ChequeKind, c: Loaded): ChequeDto {
    return ChequesService.toDto(kind, c, c.partyId, c.partyName);
  }

  private static toDto(
    kind: ChequeKind,
    p: ChequeFields,
    partyId: string,
    partyName: string,
  ): ChequeDto {
    return {
      id: p.id,
      kind,
      partyId,
      partyName,
      amount: p.amount,
      number: p.chequeNumber ?? '',
      bank: p.chequeBank ?? '',
      dueDate: p.chequeDueDate?.toISOString().slice(0, 10) ?? null,
      status: p.chequeStatus!,
      paidAt: p.paidAt,
      statusAt: p.chequeStatusAt,
    };
  }
}

interface ChequeFields {
  id: string;
  amount: number;
  paidAt: Date;
  chequeNumber: string | null;
  chequeBank: string | null;
  chequeDueDate: Date | null;
  chequeStatus: 'EN_PORTEFEUILLE' | 'ENCAISSE' | 'REJETE' | null;
  chequeStatusAt: Date | null;
}

type Loaded = ChequeFields & {
  userId: string;
  saleId: string | null;
  partyId: string;
  partyName: string;
  reversedBy: { id: string } | null;
};
