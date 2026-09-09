import { HttpStatus, Logger } from '@nestjs/common';
import { AuthenticatedUser, RoleCode } from '../common/auth.decorators';
import { BusinessException } from '../common/business.exception';
import { ErrorCode } from '../common/error-codes';
import { PERMISSIONS } from '../common/permissions';
import { Prisma } from '../generated/prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import {
  AuditAction,
  OperationType,
  SyncMutationStatus,
} from '../generated/prisma/enums';
import {
  SyncMutationDto,
  SyncOperationTypeDto,
  SyncResultStatusDto,
} from './dto/sync.dto';
import { SyncMutationHandler } from './sync-mutation.handler';
import { SyncService } from './sync.service';

/// Tests du MOTEUR de synchronisation : idempotence, permissions, ordre, rejets.
/// L'effet métier réel (stock) est couvert par `test/sync.e2e-spec.ts` sur la vraie base.
describe('SyncService', () => {
  const magasinier: AuthenticatedUser = {
    id: '00000000-0000-4000-8000-000000000001',
    roles: ['MAGASINIER'],
    permissions: [PERMISSIONS.STOCK_LOSS],
    mustChangePassword: false,
  };

  const mutation = (over: Partial<SyncMutationDto> = {}): SyncMutationDto => ({
    clientMutationId: '11111111-1111-4111-8111-111111111111',
    deviceId: 'mobile-magasinier-01',
    operationType: SyncOperationTypeDto.MANUAL,
    payload: { productId: 'p1', quantity: '3.000' },
    deviceTimestamp: new Date('2026-09-09T08:00:00.000Z'),
    ...over,
  });

  let handler: jest.Mocked<SyncMutationHandler>;
  let tx: { syncMutation: any; auditLog: any };
  let prisma: any;
  let service: SyncService;

  beforeEach(() => {
    handler = {
      operationType: OperationType.MANUAL,
      requiredRoles: [RoleCode.ADMIN, RoleCode.MAGASINIER],
      requiredPermissions: [PERMISSIONS.STOCK_LOSS],
      auditEntityType: 'StockMovement',
      auditAction: AuditAction.ADJUST,
      validate: jest.fn(async (payload: unknown) => payload as object),
      apply: jest.fn(async () => ({ entityId: 'movement-1' })),
    } as unknown as jest.Mocked<SyncMutationHandler>;

    tx = {
      syncMutation: { create: jest.fn(), update: jest.fn() },
      auditLog: { create: jest.fn() },
    };
    prisma = {
      syncMutation: { findUnique: jest.fn().mockResolvedValue(null), create: jest.fn() },
      $transaction: jest.fn(async (run: (c: unknown) => unknown) => run(tx)),
    };

    service = new SyncService(prisma as PrismaService, [handler]);
  });

  it('applique une mutation valide et trace l’audit dans la même transaction', async () => {
    const result = await service.processBatch({ mutations: [mutation()] }, magasinier);

    expect(result.results[0]).toMatchObject({
      status: SyncResultStatusDto.CONFIRMEE,
      entityId: 'movement-1',
      alreadyProcessed: false,
    });
    expect(handler.apply).toHaveBeenCalledTimes(1);
    expect(tx.auditLog.create).toHaveBeenCalledTimes(1);
    // L'audit référence bien l'entité créée, pas la mutation.
    expect(tx.auditLog.create.mock.calls[0][0].data).toMatchObject({
      entityType: 'StockMovement',
      entityId: 'movement-1',
      userId: magasinier.id,
    });
  });

  it('ne rejoue JAMAIS une mutation déjà traitée (idempotence)', async () => {
    prisma.syncMutation.findUnique.mockResolvedValue({
      clientMutationId: mutation().clientMutationId,
      userId: magasinier.id,
      status: SyncMutationStatus.CONFIRMEE,
      resultEntityId: 'movement-1',
      rejectionCode: null,
      rejectionReason: null,
    });

    const result = await service.processBatch({ mutations: [mutation()] }, magasinier);

    expect(result.results[0]).toMatchObject({
      status: SyncResultStatusDto.CONFIRMEE,
      entityId: 'movement-1',
      alreadyProcessed: true,
    });
    expect(handler.apply).not.toHaveBeenCalled();
    expect(prisma.$transaction).not.toHaveBeenCalled();
  });

  it('renvoie le rejet mémorisé, avec son code stable, sur un renvoi', async () => {
    prisma.syncMutation.findUnique.mockResolvedValue({
      clientMutationId: mutation().clientMutationId,
      userId: magasinier.id,
      status: SyncMutationStatus.REJETEE,
      resultEntityId: null,
      rejectionCode: ErrorCode.STOCK_NEGATIVE,
      rejectionReason: 'Stock insuffisant pour « Câble 3G2.5 »',
    });

    const [result] = (
      await service.processBatch({ mutations: [mutation()] }, magasinier)
    ).results;

    expect(result.status).toBe(SyncResultStatusDto.REJETEE);
    expect(result.code).toBe(ErrorCode.STOCK_NEGATIVE);
    expect(result.alreadyProcessed).toBe(true);
    expect(handler.apply).not.toHaveBeenCalled();
  });

  it('rejette une mutation dont l’utilisateur n’a pas la permission — comme en ligne', async () => {
    const sansPermission: AuthenticatedUser = { ...magasinier, permissions: [] };

    const [result] = (
      await service.processBatch({ mutations: [mutation()] }, sansPermission)
    ).results;

    expect(result.status).toBe(SyncResultStatusDto.REJETEE);
    expect(result.code).toBe(ErrorCode.FORBIDDEN_PERMISSION);
    expect(handler.apply).not.toHaveBeenCalled();
    // Rejet définitif : mémorisé pour que le renvoi donne le même verdict.
    expect(prisma.syncMutation.create.mock.calls[0][0].data).toMatchObject({
      status: SyncMutationStatus.REJETEE,
      rejectionCode: ErrorCode.FORBIDDEN_PERMISSION,
    });
  });

  it('rejette la mutation d’un membre qui a la permission mais PAS le rôle', async () => {
    // Cas réel : l'admin accorde `stock.loss` à un vendeur « à la carte ». En ligne,
    // `POST /stock/losses` le refuse (rôle ADMIN/MAGASINIER) — le sync doit faire pareil,
    // sinon il devient une porte dérobée sur la matrice de permissions.
    const vendeurAvecPermission: AuthenticatedUser = {
      ...magasinier,
      roles: ['VENDEUR'],
      permissions: [PERMISSIONS.STOCK_LOSS],
    };

    const [result] = (
      await service.processBatch({ mutations: [mutation()] }, vendeurAvecPermission)
    ).results;

    expect(result.status).toBe(SyncResultStatusDto.REJETEE);
    expect(result.code).toBe(ErrorCode.FORBIDDEN_ROLE);
    expect(handler.apply).not.toHaveBeenCalled();
  });

  it('ne divulgue JAMAIS le résultat mémorisé d’un autre utilisateur', async () => {
    prisma.syncMutation.findUnique.mockResolvedValue({
      clientMutationId: mutation().clientMutationId,
      userId: 'un-autre-utilisateur',
      status: SyncMutationStatus.CONFIRMEE,
      resultEntityId: 'movement-de-quelqu-un-d-autre',
      rejectionCode: null,
      rejectionReason: null,
    });

    const [result] = (
      await service.processBatch({ mutations: [mutation()] }, magasinier)
    ).results;

    expect(result.status).toBe(SyncResultStatusDto.REJETEE);
    expect(result.code).toBe(ErrorCode.CONFLICT);
    expect(result.entityId).toBeUndefined();
    // Surtout pas `alreadyProcessed: true` : l'appelant croirait SON opération appliquée.
    expect(result.alreadyProcessed).toBe(false);
  });

  it('rejette DÉFINITIVEMENT un identifiant d’entité déjà pris, sans geler la file', async () => {
    // Le client fournit ses UUID (contrat §1) : un id déjà utilisé ne passera jamais.
    // Le renvoyer en « réessayer plus tard » bloquerait la file de l'appareil pour toujours.
    handler.apply.mockRejectedValueOnce(
      new Prisma.PrismaClientKnownRequestError('Unique constraint failed', {
        code: 'P2002',
        clientVersion: '7.10.0',
        meta: { target: ['id'] },
      }),
    );

    const { results } = await service.processBatch(
      {
        mutations: [
          mutation({
            clientMutationId: '11111111-1111-4111-8111-111111111111',
            deviceTimestamp: new Date('2026-09-09T08:00:01.000Z'),
          }),
          mutation({
            clientMutationId: '22222222-2222-4222-8222-222222222222',
            deviceTimestamp: new Date('2026-09-09T08:00:02.000Z'),
          }),
        ],
      },
      magasinier,
    );

    expect(results[0]).toMatchObject({
      status: SyncResultStatusDto.REJETEE,
      code: ErrorCode.CONFLICT,
    });
    // Un rejet n'arrête pas le lot : la mutation suivante est bien traitée.
    expect(results[1].status).toBe(SyncResultStatusDto.CONFIRMEE);
  });

  it('rejette un payload invalide sans ouvrir de transaction', async () => {
    handler.validate.mockRejectedValue(
      new BusinessException(
        ErrorCode.VALIDATION_FAILED,
        'Payload invalide — quantity : quantité décimale invalide',
        HttpStatus.UNPROCESSABLE_ENTITY,
      ),
    );

    const [result] = (
      await service.processBatch({ mutations: [mutation()] }, magasinier)
    ).results;

    expect(result.status).toBe(SyncResultStatusDto.REJETEE);
    expect(result.code).toBe(ErrorCode.VALIDATION_FAILED);
    expect(prisma.$transaction).not.toHaveBeenCalled();
    expect(prisma.syncMutation.create).toHaveBeenCalledTimes(1);
  });

  it('rejette une règle métier violée en gardant le motif lisible', async () => {
    handler.apply.mockRejectedValue(
      new BusinessException(
        ErrorCode.STOCK_NEGATIVE,
        'Stock insuffisant pour « Câble 3G2.5 » : disponible 2.000, demandé 5.000',
        HttpStatus.UNPROCESSABLE_ENTITY,
      ),
    );

    const [result] = (
      await service.processBatch({ mutations: [mutation()] }, magasinier)
    ).results;

    expect(result.status).toBe(SyncResultStatusDto.REJETEE);
    expect(result.code).toBe(ErrorCode.STOCK_NEGATIVE);
    expect(result.reason).toContain('disponible 2.000');
    expect(prisma.syncMutation.create.mock.calls[0][0].data.status).toBe(
      SyncMutationStatus.REJETEE,
    );
  });

  it('garde en file une opération dont le handler n’existe pas encore', async () => {
    const [result] = (
      await service.processBatch(
        { mutations: [mutation({ operationType: SyncOperationTypeDto.SALE })] },
        magasinier,
      )
    ).results;

    expect(result.status).toBe(SyncResultStatusDto.NON_TRAITEE);
    expect(result.code).toBe(ErrorCode.NOT_IMPLEMENTED);
    // Rien de mémorisé : la mutation sera acceptée quand la feature sortira.
    expect(prisma.syncMutation.create).not.toHaveBeenCalled();
  });

  it('rejoue le lot dans l’ordre du timestamp appareil, quel que soit l’ordre d’envoi', async () => {
    const seen: string[] = [];
    handler.apply.mockImplementation(async (payload: any) => {
      seen.push(payload.tag);
      return { entityId: `movement-${payload.tag}` };
    });

    await service.processBatch(
      {
        mutations: [
          mutation({
            clientMutationId: '33333333-3333-4333-8333-333333333333',
            payload: { tag: 'C' },
            deviceTimestamp: new Date('2026-09-09T08:00:03.000Z'),
          }),
          mutation({
            clientMutationId: '11111111-1111-4111-8111-111111111111',
            payload: { tag: 'A' },
            deviceTimestamp: new Date('2026-09-09T08:00:01.000Z'),
          }),
          mutation({
            clientMutationId: '22222222-2222-4222-8222-222222222222',
            payload: { tag: 'B' },
            deviceTimestamp: new Date('2026-09-09T08:00:02.000Z'),
          }),
        ],
      },
      magasinier,
    );

    expect(seen).toEqual(['A', 'B', 'C']);
  });

  it('n’écrit rien et arrête le lot sur une panne technique (ordre préservé)', async () => {
    jest.spyOn(Logger.prototype, 'error').mockImplementation(() => undefined);
    handler.apply.mockRejectedValueOnce(new Error('connexion base perdue'));

    const { results } = await service.processBatch(
      {
        mutations: [
          mutation({
            clientMutationId: '11111111-1111-4111-8111-111111111111',
            deviceTimestamp: new Date('2026-09-09T08:00:01.000Z'),
          }),
          mutation({
            clientMutationId: '22222222-2222-4222-8222-222222222222',
            deviceTimestamp: new Date('2026-09-09T08:00:02.000Z'),
          }),
        ],
      },
      magasinier,
    );

    expect(results[0]).toMatchObject({
      status: SyncResultStatusDto.NON_TRAITEE,
      code: ErrorCode.SYNC_RETRY_LATER,
    });
    expect(results[1].status).toBe(SyncResultStatusDto.NON_TRAITEE);
    // La 2e n'a même pas été tentée : la file reste ordonnée.
    expect(handler.apply).toHaveBeenCalledTimes(1);
    expect(prisma.syncMutation.create).not.toHaveBeenCalled();
  });
});
