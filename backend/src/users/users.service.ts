import { HttpStatus, Injectable } from '@nestjs/common';
import { AuthService } from '../auth/auth.service';
import { RoleCode } from '../common/auth.decorators';
import { BusinessException } from '../common/business.exception';
import { PaginationQueryDto } from '../common/dto/pagination.dto';
import { ErrorCode } from '../common/error-codes';
import { PrismaService } from '../prisma/prisma.service';
import { Prisma } from '../generated/prisma/client';
import {
  CreateUserDto,
  ResetPasswordDto,
  UpdateUserDto,
  UserDto,
  UserListDto,
} from './dto/user.dto';

type UserRow = {
  id: string;
  email: string | null;
  phone: string | null;
  fullName: string;
  isActive: boolean;
  mustChangePassword: boolean;
  lastLoginAt: Date | null;
  createdAt: Date;
  roles: { code: string; permissions: { code: string }[] }[];
  permissions: { code: string }[];
};

/// Qui agit, et depuis où — indispensable pour tracer une action sensible.
export interface ActorContext {
  userId: string;
  ipAddress?: string;
}

/// Transaction Prisma (le client restreint passé à `$transaction`).
type Tx = Prisma.TransactionClient;

@Injectable()
export class UsersService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly authService: AuthService,
  ) {}

  private static readonly INCLUDE = {
    roles: { include: { permissions: { select: { code: true } } } },
    permissions: { select: { code: true } },
  } as const;

  private static toDto(user: UserRow): UserDto {
    const fromRoles = user.roles.flatMap((r) => r.permissions.map((p) => p.code));
    const direct = user.permissions.map((p) => p.code);
    return {
      id: user.id,
      email: user.email,
      phone: user.phone,
      fullName: user.fullName,
      isActive: user.isActive,
      mustChangePassword: user.mustChangePassword,
      roles: user.roles.map((r) => r.code),
      permissions: [...new Set([...fromRoles, ...direct])].sort(),
      lastLoginAt: user.lastLoginAt,
      createdAt: user.createdAt,
    };
  }

  /// Instantané d'un compte destiné à `AuditLog`.
  ///
  /// Ne contient JAMAIS `passwordHash` ni un mot de passe en clair : le journal
  /// est consultable par l'admin et ne doit pas devenir une fuite de secrets.
  private static auditSnapshot(user: UserDto): Prisma.InputJsonValue {
    return {
      email: user.email,
      phone: user.phone,
      fullName: user.fullName,
      isActive: user.isActive,
      mustChangePassword: user.mustChangePassword,
      roles: user.roles,
      permissions: user.permissions,
    };
  }

  /// Écrit la trace d'une action sensible.
  ///
  /// Toujours appelée AVEC la transaction de la mutation (règle 3 + règle 7) :
  /// une modification de compte sans trace devient impossible par construction,
  /// et une trace sans modification aussi.
  private static async writeAudit(
    tx: Tx,
    actor: ActorContext,
    params: {
      action: 'CREATE' | 'UPDATE';
      entityId: string;
      oldValue?: Prisma.InputJsonValue;
      newValue?: Prisma.InputJsonValue;
    },
  ): Promise<void> {
    await tx.auditLog.create({
      data: {
        userId: actor.userId,
        action: params.action,
        entityType: 'User',
        entityId: params.entityId,
        oldValue: params.oldValue,
        newValue: params.newValue,
        ipAddress: actor.ipAddress ?? null,
      },
    });
  }

  /// Création par l'admin uniquement (pas d'inscription publique) :
  /// le mot de passe fourni est TEMPORAIRE, `mustChangePassword` est forcé à vrai.
  async create(dto: CreateUserDto, actor: ActorContext): Promise<UserDto> {
    if (!dto.email && !dto.phone) {
      throw new BusinessException(
        ErrorCode.VALIDATION_FAILED,
        'Fournir au moins un email ou un téléphone',
      );
    }
    await this.assertIdentifiersFree(dto.email, dto.phone);

    const passwordHash = await AuthService.hashPassword(dto.temporaryPassword);

    return this.prisma.$transaction(async (tx) => {
      const user = (await tx.user.create({
        data: {
          email: dto.email ?? null,
          phone: dto.phone ?? null,
          fullName: dto.fullName,
          passwordHash,
          mustChangePassword: true,
          roles: { connect: dto.roles.map((code) => ({ code })) },
          permissions: dto.extraPermissions?.length
            ? { connect: dto.extraPermissions.map((code) => ({ code })) }
            : undefined,
        },
        include: UsersService.INCLUDE,
      })) as UserRow;

      const created = UsersService.toDto(user);
      await UsersService.writeAudit(tx, actor, {
        action: 'CREATE',
        entityId: created.id,
        newValue: UsersService.auditSnapshot(created),
      });
      return created;
    });
  }

  async findAll(query: PaginationQueryDto): Promise<UserListDto> {
    const where = query.q
      ? {
          OR: [
            { fullName: { contains: query.q, mode: 'insensitive' as const } },
            { email: { contains: query.q, mode: 'insensitive' as const } },
            { phone: { contains: query.q } },
          ],
        }
      : {};

    const [rows, total] = await Promise.all([
      this.prisma.user.findMany({
        where,
        include: UsersService.INCLUDE,
        skip: (query.page - 1) * query.limit,
        take: query.limit,
        orderBy: { createdAt: 'desc' },
      }),
      this.prisma.user.count({ where }),
    ]);

    return {
      data: (rows as UserRow[]).map(UsersService.toDto),
      meta: { page: query.page, limit: query.limit, total },
    };
  }

  async findOne(id: string): Promise<UserDto> {
    const user = (await this.prisma.user.findUnique({
      where: { id },
      include: UsersService.INCLUDE,
    })) as UserRow | null;
    if (!user) {
      throw new BusinessException(
        ErrorCode.NOT_FOUND,
        'Utilisateur introuvable',
        HttpStatus.NOT_FOUND,
      );
    }
    return UsersService.toDto(user);
  }

  async update(
    id: string,
    dto: UpdateUserDto,
    actor: ActorContext,
  ): Promise<UserDto> {
    const before = await this.findOne(id);
    await this.assertIdentifiersFree(dto.email, dto.phone, id);

    // Filet de sécurité : ne jamais laisser le système sans aucun admin actif,
    // sinon plus personne ne peut administrer (seule sortie = intervention en base).
    const losesAdmin =
      before.roles.includes(RoleCode.ADMIN) &&
      ((dto.roles && !dto.roles.includes(RoleCode.ADMIN)) || dto.isActive === false);
    if (losesAdmin) {
      const remainingAdmins = await this.prisma.user.count({
        where: { isActive: true, roles: { some: { code: RoleCode.ADMIN } }, NOT: { id } },
      });
      if (remainingAdmins === 0) {
        throw new BusinessException(
          ErrorCode.CONFLICT,
          'Impossible : ce compte est le dernier administrateur actif',
          HttpStatus.CONFLICT,
        );
      }
    }

    return this.prisma.$transaction(async (tx) => {
      const user = (await tx.user.update({
        where: { id },
        data: {
          fullName: dto.fullName,
          email: dto.email,
          phone: dto.phone,
          isActive: dto.isActive,
          roles: dto.roles ? { set: dto.roles.map((code) => ({ code })) } : undefined,
          permissions: dto.extraPermissions
            ? { set: dto.extraPermissions.map((code) => ({ code })) }
            : undefined,
        },
        include: UsersService.INCLUDE,
      })) as UserRow;

      // Un compte désactivé ne doit plus pouvoir rafraîchir sa session.
      // Révoqué DANS la transaction : sinon un échec ultérieur laisserait un
      // compte marqué inactif mais toujours capable de renouveler ses tokens.
      if (dto.isActive === false) {
        await UsersService.revokeAllInTx(tx, id);
      }

      const after = UsersService.toDto(user);
      await UsersService.writeAudit(tx, actor, {
        action: 'UPDATE',
        entityId: id,
        oldValue: UsersService.auditSnapshot(before),
        newValue: UsersService.auditSnapshot(after),
      });
      return after;
    });
  }

  /// Réinitialisation par l'admin : nouveau mot de passe temporaire, sessions coupées.
  async resetPassword(
    id: string,
    dto: ResetPasswordDto,
    actor: ActorContext,
  ): Promise<UserDto> {
    await this.findOne(id);
    const passwordHash = await AuthService.hashPassword(dto.temporaryPassword);

    return this.prisma.$transaction(async (tx) => {
      const user = (await tx.user.update({
        where: { id },
        data: { passwordHash, mustChangePassword: true },
        include: UsersService.INCLUDE,
      })) as UserRow;

      const revoked = await UsersService.revokeAllInTx(tx, id);

      // Le mot de passe lui-même n'apparaît JAMAIS dans le journal : on ne trace
      // que le fait qu'une réinitialisation a eu lieu.
      await UsersService.writeAudit(tx, actor, {
        action: 'UPDATE',
        entityId: id,
        newValue: {
          operation: 'PASSWORD_RESET',
          mustChangePassword: true,
          revokedSessions: revoked,
        },
      });
      return UsersService.toDto(user);
    });
  }

  async revokeSessions(
    id: string,
    actor: ActorContext,
  ): Promise<{ revoked: number }> {
    await this.findOne(id);

    return this.prisma.$transaction(async (tx) => {
      const revoked = await UsersService.revokeAllInTx(tx, id);
      await UsersService.writeAudit(tx, actor, {
        action: 'UPDATE',
        entityId: id,
        newValue: { operation: 'REVOKE_SESSIONS', revokedSessions: revoked },
      });
      return { revoked };
    });
  }

  /// Révocation dans la transaction de l'appelant.
  /// Duplique volontairement `AuthService.revokeAllForUser` : ce dernier utilise
  /// sa propre connexion et casserait l'atomicité.
  private static async revokeAllInTx(tx: Tx, userId: string): Promise<number> {
    const result = await tx.refreshToken.updateMany({
      where: { userId, revokedAt: null },
      data: { revokedAt: new Date() },
    });
    return result.count;
  }

  private async assertIdentifiersFree(
    email?: string,
    phone?: string,
    exceptUserId?: string,
  ): Promise<void> {
    const clauses = [
      ...(email ? [{ email }] : []),
      ...(phone ? [{ phone }] : []),
    ];
    if (clauses.length === 0) return;

    const existing = await this.prisma.user.findFirst({
      where: {
        OR: clauses,
        ...(exceptUserId ? { NOT: { id: exceptUserId } } : {}),
      },
      select: { id: true },
    });
    if (existing) {
      throw new BusinessException(
        ErrorCode.CONFLICT,
        'Email ou téléphone déjà utilisé par un autre compte',
        HttpStatus.CONFLICT,
      );
    }
  }
}
