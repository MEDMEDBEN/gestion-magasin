import { Inject, Injectable, Logger } from '@nestjs/common';
import { AuthenticatedUser } from '../common/auth.decorators';
import { BusinessException } from '../common/business.exception';
import { ErrorCode } from '../common/error-codes';
import { Prisma } from '../generated/prisma/client';
import { OperationType, SyncMutationStatus } from '../generated/prisma/enums';
import { PrismaService } from '../prisma/prisma.service';
import {
  SyncBatchDto,
  SyncBatchResultDto,
  SyncMutationDto,
  SyncMutationResultDto,
  SyncResultStatusDto,
} from './dto/sync.dto';
import {
  SYNC_MUTATION_HANDLERS,
  SyncMutationHandler,
} from './sync-mutation.handler';

/// Ligne de mémoire d'idempotence relue pour renvoyer un résultat déjà calculé.
type MemorizedMutation = {
  clientMutationId: string;
  userId: string;
  status: SyncMutationStatus;
  resultEntityId: string | null;
  rejectionCode: string | null;
  rejectionReason: string | null;
};

const MEMORY_SELECT = {
  clientMutationId: true,
  userId: true,
  status: true,
  resultEntityId: true,
  rejectionCode: true,
  rejectionReason: true,
} as const;

/// Moteur de synchronisation hors-ligne — application STRICTE de `docs/context.md` §3-§5.
///
/// Garanties, dans cet ordre, pour chaque mutation :
///  1. **Idempotence** — `clientMutationId` déjà vu ⇒ on renvoie le résultat mémorisé,
///     on ne rejoue rien (un mouvement de stock n'est jamais appliqué deux fois).
///  2. **Permissions** — les mêmes qu'en ligne ; un manque est définitif ⇒ REJET mémorisé.
///  3. **Validation** — payload non conforme ⇒ REJET mémorisé (il échouera toujours).
///  4. **Règle métier** en transaction ⇒ CONFIRMÉE, ou REJET qui n'applique RIEN.
///
/// Un échec technique (base indisponible, bug) n'est jamais mémorisé : la mutation
/// repart `NON_TRAITEE` et le client la renverra. Le lot s'arrête alors, pour que
/// l'ordre du timestamp appareil soit préservé sur la reprise.
@Injectable()
export class SyncService {
  private readonly logger = new Logger(SyncService.name);
  private readonly handlers = new Map<OperationType, SyncMutationHandler>();

  constructor(
    private readonly prisma: PrismaService,
    @Inject(SYNC_MUTATION_HANDLERS) handlers: SyncMutationHandler[],
  ) {
    for (const handler of handlers) {
      this.handlers.set(handler.operationType, handler);
    }
  }

  async processBatch(
    dto: SyncBatchDto,
    user: AuthenticatedUser,
    ipAddress?: string,
  ): Promise<SyncBatchResultDto> {
    // Le client envoie déjà dans l'ordre (contrat §2) ; on retrie par sécurité, l'ordre
    // d'envoi départageant deux horodatages identiques.
    const ordered = dto.mutations
      .map((mutation, index) => ({ mutation, index }))
      .sort(
        (a, b) =>
          a.mutation.deviceTimestamp.getTime() -
            b.mutation.deviceTimestamp.getTime() || a.index - b.index,
      );

    // Prérequis N6b : les mutations d'un AUTRE compte ne sont jamais traitées
    // avec cette session — elles lui seraient attribuées (et jugées selon SES
    // droits). Rien n'est mémorisé : elles repartiront avec la bonne session.
    if (dto.authorUserId !== user.id) {
      // Normal après un changement de compte ; répété sur un appareil, c'est un
      // client trafiqué. Jamais le contenu des mutations dans le journal.
      this.logger.warn(
        `Lot refusé (auteur) : session ${user.id}, auteur déclaré ${dto.authorUserId}, ` +
          `appareil ${ordered[0]?.mutation.deviceId}, ${ordered.length} mutation(s)`,
      );
      return {
        serverTime: new Date(),
        results: ordered.map(({ mutation }) =>
          this.pending(
            mutation,
            ErrorCode.SYNC_AUTHOR_MISMATCH,
            'Non traitée : ces opérations appartiennent à un autre compte que celui ' +
              'connecté — elles partiront avec la session de leur auteur',
          ),
        ),
      };
    }

    const results: SyncMutationResultDto[] = [];
    let halted = false;

    for (const { mutation } of ordered) {
      if (halted) {
        results.push(
          this.pending(
            mutation,
            ErrorCode.SYNC_RETRY_LATER,
            'Non traitée : une mutation précédente du lot a échoué — l’ordre est préservé, renvoyer le reste de la file',
          ),
        );
        continue;
      }

      const result = await this.processOne(mutation, user, ipAddress);
      results.push(result);

      if (
        result.status === SyncResultStatusDto.NON_TRAITEE &&
        result.code === ErrorCode.SYNC_RETRY_LATER
      ) {
        halted = true;
      }
    }

    return { serverTime: new Date(), results };
  }

  private async processOne(
    mutation: SyncMutationDto,
    user: AuthenticatedUser,
    ipAddress?: string,
  ): Promise<SyncMutationResultDto> {
    // 1. Idempotence — déjà traitée ⇒ on renvoie l'ancien résultat, on s'arrête là.
    const memorized = await this.prisma.syncMutation.findUnique({
      where: { clientMutationId: mutation.clientMutationId },
      select: MEMORY_SELECT,
    });
    if (memorized) return this.fromMemoryFor(memorized, mutation, user);

    const handler = this.handlers.get(
      mutation.operationType as unknown as OperationType,
    );
    if (!handler) {
      return this.pending(
        mutation,
        ErrorCode.NOT_IMPLEMENTED,
        `Aucun handler pour « ${mutation.operationType} » sur cette version du serveur — mutation conservée dans la file`,
      );
    }

    // 2. Rôle PUIS permissions — la matrice de docs/permissions.md exige les deux, et
    //    l'API en ligne les vérifie tous les deux. Le sync ne doit pas être une porte
    //    dérobée pour un membre à qui l'admin a accordé la permission sans le rôle.
    if (!handler.requiredRoles.some((role) => user.roles.includes(role))) {
      return this.refuse(
        mutation,
        user,
        ErrorCode.FORBIDDEN_ROLE,
        `Rôle insuffisant pour « ${mutation.operationType} » : ${handler.requiredRoles.join(' ou ')} requis`,
      );
    }

    const missing = handler.requiredPermissions.filter(
      (permission) => !user.permissions.includes(permission),
    );
    if (missing.length > 0) {
      return this.refuse(
        mutation,
        user,
        ErrorCode.FORBIDDEN_PERMISSION,
        `Permission manquante : ${missing.join(', ')}`,
      );
    }

    // 3. Validation du payload — un payload invalide le restera : rejet définitif.
    let payload: object;
    try {
      payload = await handler.validate(mutation.payload);
    } catch (error) {
      if (error instanceof BusinessException) {
        return this.memorizeRejection(
          mutation,
          user,
          SyncService.codeOf(error, ErrorCode.VALIDATION_FAILED),
          SyncService.messageOf(error),
        );
      }
      throw error;
    }

    // 4. Application — tout ou rien.
    try {
      const applied = await this.prisma.$transaction(async (tx) => {
        // La mutation est « réservée » dans la MÊME transaction que son effet :
        // l'unicité de `clientMutationId` sérialise deux envois concurrents du même
        // lot, et un rejet annule la réservation en même temps que l'effet.
        await tx.syncMutation.create({
          data: {
            clientMutationId: mutation.clientMutationId,
            userId: user.id,
            deviceId: mutation.deviceId,
            operationType: mutation.operationType as unknown as OperationType,
            payload: mutation.payload as Prisma.InputJsonValue,
            status: SyncMutationStatus.CONFIRMEE,
            deviceTimestamp: mutation.deviceTimestamp,
          },
        });

        const outcome = await handler.apply(payload, {
          tx,
          user,
          deviceId: mutation.deviceId,
          clientMutationId: mutation.clientMutationId,
          deviceTimestamp: mutation.deviceTimestamp,
        });

        // Historique immuable (règle 7) + contrat §4.4 : l'audit est écrit ICI, dans la
        // transaction — une mutation appliquée sans trace est impossible par construction.
        await tx.auditLog.create({
          data: {
            userId: user.id,
            action: handler.auditAction,
            entityType: handler.auditEntityType,
            entityId: outcome.entityId,
            // Toujours l'instantané CHOISI par le handler, jamais le payload
            // brut du client (champ obligatoire de `SyncApplyResult`).
            newValue: outcome.auditNewValue,
            ipAddress: ipAddress ?? null,
          },
        });

        await tx.syncMutation.update({
          where: { clientMutationId: mutation.clientMutationId },
          data: { resultEntityId: outcome.entityId },
        });

        return outcome;
      });

      return {
        clientMutationId: mutation.clientMutationId,
        status: SyncResultStatusDto.CONFIRMEE,
        entityId: applied.entityId,
        serverState: applied.serverState,
        alreadyProcessed: false,
      };
    } catch (error) {
      // Course d'idempotence : l'autre requête a gagné, son résultat fait foi.
      if (SyncService.isUniqueViolationOn(error, 'clientMutationId')) {
        const concurrent = await this.prisma.syncMutation.findUnique({
          where: { clientMutationId: mutation.clientMutationId },
          select: MEMORY_SELECT,
        });
        if (concurrent) return this.fromMemoryFor(concurrent, mutation, user);
      }

      // Toute AUTRE violation d'unicité vient des données du client — typiquement un `id`
      // d'entité déjà utilisé (le client fournit ses UUID, contrat §1). C'est DÉFINITIF :
      // le renvoyer en « réessayer plus tard » gèlerait la file de l'appareil pour toujours.
      if (SyncService.isUniqueViolation(error)) {
        return this.memorizeRejection(
          mutation,
          user,
          ErrorCode.CONFLICT,
          'Identifiant déjà utilisé par une autre opération — regénérer l’opération côté client',
        );
      }

      if (error instanceof BusinessException) {
        return this.memorizeRejection(
          mutation,
          user,
          SyncService.codeOf(error, ErrorCode.SYNC_MUTATION_REJECTED),
          SyncService.messageOf(error),
        );
      }

      // Panne technique : rien n'est mémorisé, le client renverra la mutation.
      this.logger.error(
        `Échec technique sur la mutation ${mutation.clientMutationId} (${mutation.operationType})`,
        error as Error,
      );
      return this.pending(
        mutation,
        ErrorCode.SYNC_RETRY_LATER,
        'Erreur serveur temporaire — mutation non appliquée, à renvoyer',
      );
    }
  }

  /// Refus d'accès : mémorisé comme définitif, et tracé — une tentative répétée
  /// (appareil compromis, token volé, client trafiqué) doit être visible en supervision.
  private refuse(
    mutation: SyncMutationDto,
    user: AuthenticatedUser,
    code: ErrorCode,
    reason: string,
  ): Promise<SyncMutationResultDto> {
    this.logger.warn(
      `Mutation refusée (${code}) — user ${user.id}, appareil ${mutation.deviceId}, ` +
        `opération ${mutation.operationType} : ${reason}`,
    );
    return this.memorizeRejection(mutation, user, code, reason);
  }

  /// Renvoie le résultat mémorisé — mais SEULEMENT à son propriétaire. Un
  /// `clientMutationId` déjà pris par quelqu'un d'autre ne doit rien divulguer, et surtout
  /// pas faire croire à l'appelant que SON opération a été appliquée.
  private fromMemoryFor(
    memorized: MemorizedMutation,
    mutation: SyncMutationDto,
    user: AuthenticatedUser,
  ): SyncMutationResultDto {
    if (memorized.userId !== user.id) {
      this.logger.warn(
        `clientMutationId ${mutation.clientMutationId} déjà utilisé par un autre compte ` +
          `(demandé par ${user.id}, appareil ${mutation.deviceId})`,
      );
      return {
        clientMutationId: mutation.clientMutationId,
        status: SyncResultStatusDto.REJETEE,
        code: ErrorCode.CONFLICT,
        reason:
          'Identifiant de mutation déjà utilisé — regénérer l’opération côté client',
        alreadyProcessed: false,
      };
    }
    return SyncService.fromMemory(memorized);
  }

  /// Mémorise un rejet définitif : un renvoi de la même mutation renverra ce rejet
  /// sans le recalculer. Corriger l'opération côté client = une NOUVELLE mutation.
  private async memorizeRejection(
    mutation: SyncMutationDto,
    user: AuthenticatedUser,
    code: ErrorCode,
    reason: string,
  ): Promise<SyncMutationResultDto> {
    try {
      await this.prisma.syncMutation.create({
        data: {
          clientMutationId: mutation.clientMutationId,
          userId: user.id,
          deviceId: mutation.deviceId,
          operationType: mutation.operationType as unknown as OperationType,
          payload: mutation.payload as Prisma.InputJsonValue,
          status: SyncMutationStatus.REJETEE,
          rejectionCode: code,
          rejectionReason: reason,
          deviceTimestamp: mutation.deviceTimestamp,
        },
      });
    } catch (error) {
      if (SyncService.isUniqueViolationOn(error, 'clientMutationId')) {
        const concurrent = await this.prisma.syncMutation.findUnique({
          where: { clientMutationId: mutation.clientMutationId },
          select: MEMORY_SELECT,
        });
        if (concurrent) return this.fromMemoryFor(concurrent, mutation, user);
      }
      throw error;
    }

    return {
      clientMutationId: mutation.clientMutationId,
      status: SyncResultStatusDto.REJETEE,
      code,
      reason,
      alreadyProcessed: false,
    };
  }

  /// Résultat NON définitif : rien n'est écrit, la mutation reste dans la file du client.
  private pending(
    mutation: SyncMutationDto,
    code: ErrorCode,
    reason: string,
  ): SyncMutationResultDto {
    return {
      clientMutationId: mutation.clientMutationId,
      status: SyncResultStatusDto.NON_TRAITEE,
      code,
      reason,
      alreadyProcessed: false,
    };
  }

  private static fromMemory(row: MemorizedMutation): SyncMutationResultDto {
    const rejected = row.status === SyncMutationStatus.REJETEE;
    return {
      clientMutationId: row.clientMutationId,
      status: rejected
        ? SyncResultStatusDto.REJETEE
        : SyncResultStatusDto.CONFIRMEE,
      entityId: row.resultEntityId,
      code: rejected
        ? ((row.rejectionCode as ErrorCode | null) ??
          ErrorCode.SYNC_MUTATION_REJECTED)
        : undefined,
      reason: rejected ? (row.rejectionReason ?? undefined) : undefined,
      alreadyProcessed: true,
    };
  }

  private static isUniqueViolation(error: unknown): boolean {
    return (
      error instanceof Prisma.PrismaClientKnownRequestError &&
      error.code === 'P2002'
    );
  }

  /// Vrai si la violation d'unicité porte sur CETTE colonne.
  ///
  /// La contrainte fautive n'est pas exposée au même endroit selon le moteur : Prisma
  /// « historique » remplit `meta.target`, alors que le driver adapter PostgreSQL de
  /// Prisma 7 la met dans `meta.driverAdapterError.cause.constraint.index`
  /// (ex. `SyncMutation_clientMutationId_key`). On regarde les deux, puis le message.
  /// Se tromper ici est coûteux : confondre « course d'idempotence » et « id déjà pris »
  /// transformerait une erreur définitive en boucle de renvoi infinie.
  private static isUniqueViolationOn(error: unknown, column: string): boolean {
    if (!SyncService.isUniqueViolation(error)) return false;
    const known = error as Prisma.PrismaClientKnownRequestError;
    const meta = known.meta as
      | {
          target?: string[] | string;
          driverAdapterError?: {
            cause?: { constraint?: { index?: string; fields?: string[] } };
          };
        }
      | undefined;
    const constraint = meta?.driverAdapterError?.cause?.constraint;
    const candidates = [
      ...(Array.isArray(meta?.target) ? meta.target : [meta?.target]),
      constraint?.index,
      ...(constraint?.fields ?? []),
      known.message,
    ];
    return candidates.some((value) => String(value ?? '').includes(column));
  }

  private static codeOf(
    error: BusinessException,
    fallback: ErrorCode,
  ): ErrorCode {
    const body = error.getResponse();
    const code =
      typeof body === 'object' && body !== null
        ? (body as { code?: ErrorCode }).code
        : undefined;
    return code ?? fallback;
  }

  private static messageOf(error: BusinessException): string {
    const body = error.getResponse();
    const message =
      typeof body === 'object' && body !== null
        ? (body as { message?: string }).message
        : undefined;
    return message ?? error.message;
  }
}
