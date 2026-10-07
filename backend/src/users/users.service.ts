import { HttpStatus, Injectable } from '@nestjs/common';
import { ActorContext, writeAudit } from '../audit/audit-writer';
import { AuthService } from '../auth/auth.service';
import { hashPassword } from '../auth/password';
import { RoleCode } from '../common/auth.decorators';
import { BusinessException } from '../common/business.exception';
import { PaginationQueryDto, parseSort } from '../common/dto/pagination.dto';
import { ErrorCode } from '../common/error-codes';
import {
  resolvePermissions,
  USER_ACCESS_INCLUDE,
  UserWithAccess,
} from '../common/user-access';
import { Prisma } from '../generated/prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import {
  CreateUserDto,
  ResetPasswordDto,
  RevokedSessionsDto,
  UpdateUserDto,
  UserDto,
  UserListDto,
} from './dto/user.dto';

type Db = Prisma.TransactionClient;

/// Verrou applicatif (`pg_advisory_xact_lock`) sérialisant les mutations qui
/// peuvent retirer un administrateur actif. Sans lui, deux admins qui se
/// désactivent mutuellement au même instant passent tous deux le contrôle
/// « dernier admin » et le système se retrouve sans administrateur.
const ADMIN_SET_LOCK = BigInt(0x41444d494e); // « ADMIN » — bigint, type de pg_advisory_xact_lock

const SORTABLE_FIELDS = [
  'fullName',
  'email',
  'createdAt',
  'lastLoginAt',
] as const;

@Injectable()
export class UsersService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly authService: AuthService,
  ) {}

  private static toDto(user: UserWithAccess): UserDto {
    return {
      id: user.id,
      email: user.email,
      phone: user.phone,
      fullName: user.fullName,
      isActive: user.isActive,
      mustChangePassword: user.mustChangePassword,
      roles: user.roles.map((r) => r.code),
      permissions: resolvePermissions(user),
      lastLoginAt: user.lastLoginAt,
      createdAt: user.createdAt,
    };
  }

  /// Instantané d'un compte destiné à `AuditLog`.
  ///
  /// Ne contient JAMAIS `passwordHash` ni un mot de passe en clair : le journal
  /// est consultable par l'admin et ne doit pas devenir une fuite de secrets.
  /// Un changement de rôle modifie les permissions effectives : les deux sont
  /// tracés (spec §24 « changement de permission »).
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

  /// Création par l'admin uniquement (pas d'inscription publique) :
  /// le mot de passe fourni est TEMPORAIRE, `mustChangePassword` est forcé à vrai.
  async create(dto: CreateUserDto, actor: ActorContext): Promise<UserDto> {
    if (!dto.email && !dto.phone) {
      throw new BusinessException(
        ErrorCode.VALIDATION_FAILED,
        'Fournir au moins un email ou un téléphone',
      );
    }
    await this.assertIdentifiersFree(this.prisma, dto.email, dto.phone);

    const passwordHash = await hashPassword(dto.temporaryPassword);

    return this.prisma.$transaction(async (tx) => {
      const user = await tx.user.create({
        data: {
          email: dto.email ?? null,
          phone: dto.phone ?? null,
          fullName: dto.fullName,
          passwordHash,
          mustChangePassword: true,
          roles: { connect: dto.roles.map((code) => ({ code })) },
        },
        include: USER_ACCESS_INCLUDE,
      });

      const created = UsersService.toDto(user);
      await writeAudit(tx, actor, {
        action: 'CREATE',
        entityType: 'User',
        entityId: created.id,
        newValue: UsersService.auditSnapshot(created),
      });
      return created;
    });
  }

  async findAll(query: PaginationQueryDto): Promise<UserListDto> {
    // Un compte supprimé n'est plus listé (il reste nommé dans l'historique).
    const where: Prisma.UserWhereInput = {
      deletedAt: null,
      ...(query.q
        ? {
            OR: [
              { fullName: { contains: query.q, mode: 'insensitive' } },
              { email: { contains: query.q, mode: 'insensitive' } },
              { phone: { contains: query.q } },
            ],
          }
        : {}),
    };
    const orderBy = parseSort(query.sort, SORTABLE_FIELDS, {
      createdAt: 'desc',
    });

    const [rows, total] = await Promise.all([
      this.prisma.user.findMany({
        where,
        include: USER_ACCESS_INCLUDE,
        skip: (query.page - 1) * query.limit,
        take: query.limit,
        // `id` départage les égalités : sans lui, une page peut répéter ou sauter
        // une ligne d'une requête à l'autre.
        orderBy: [orderBy, { id: 'asc' }],
      }),
      this.prisma.user.count({ where }),
    ]);

    return {
      data: rows.map(UsersService.toDto),
      meta: { page: query.page, limit: query.limit, total },
    };
  }

  async findOne(id: string, db: Db = this.prisma): Promise<UserDto> {
    const user = await db.user.findUnique({
      where: { id },
      include: USER_ACCESS_INCLUDE,
    });
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
    // Un admin ne touche ni à ses propres rôles/permissions, ni à sa propre
    // activation : ces changements passent par un AUTRE administrateur. Ferme
    // aussi la voie de l'admin qu'on vient de rétrograder et qui tenterait de se
    // rétablir avant l'expiration de son token (audit I4).
    const touchesAccess = dto.roles !== undefined || dto.isActive !== undefined;
    // Comparaison sur la forme canonique (minuscules) : PostgreSQL retrouve la
    // même ligne quelle que soit la casse de l'UUID (contre-audit N2).
    if (actor.userId?.toLowerCase() === id.toLowerCase() && touchesAccess) {
      throw new BusinessException(
        ErrorCode.SELF_MODIFICATION_FORBIDDEN,
        'Vos rôles, permissions et activation sont modifiés par un autre administrateur',
        HttpStatus.FORBIDDEN,
      );
    }

    return this.prisma.$transaction(async (tx) => {
      // Toujours sous le verrou des comptes : une suppression concurrente ne
      // peut pas se glisser entre le contrôle « supprimé ? » et l'écriture
      // (qui rendrait son email à un compte supprimé — audit du 2026-10-07).
      await tx.$executeRaw`SELECT pg_advisory_xact_lock(${ADMIN_SET_LOCK})`;
      // Lu SOUS le verrou : l'« avant » de l'audit et le contrôle « dernier
      // admin » portent sur l'état réel, pas sur une lecture périmée.
      const before = await this.findOne(id, tx);
      await UsersService.assertNotDeleted(tx, id);
      await this.assertIdentifiersFree(tx, dto.email, dto.phone, id);

      const finalRoles = dto.roles ?? (before.roles as RoleCode[]);

      // Filet de sécurité : ne jamais laisser le système sans aucun admin actif,
      // sinon plus personne ne peut administrer (seule sortie = intervention en base).
      const losesAdmin =
        before.isActive &&
        before.roles.includes(RoleCode.ADMIN) &&
        (!finalRoles.includes(RoleCode.ADMIN) || dto.isActive === false);
      if (losesAdmin) {
        const remainingAdmins = await tx.user.count({
          where: {
            isActive: true,
            roles: { some: { code: RoleCode.ADMIN } },
            NOT: { id },
          },
        });
        if (remainingAdmins === 0) {
          throw new BusinessException(
            ErrorCode.LAST_ACTIVE_ADMIN,
            'Impossible : ce compte est le dernier administrateur actif',
            HttpStatus.CONFLICT,
          );
        }
      }

      const user = await tx.user.update({
        where: { id },
        data: {
          fullName: dto.fullName,
          email: dto.email,
          phone: dto.phone,
          isActive: dto.isActive,
          roles: dto.roles
            ? { set: dto.roles.map((code) => ({ code })) }
            : undefined,
        },
        include: USER_ACCESS_INCLUDE,
      });

      // Un compte désactivé ne doit plus pouvoir rafraîchir sa session.
      // Révoqué DANS la transaction : sinon un échec ultérieur laisserait un
      // compte marqué inactif mais toujours capable de renouveler ses tokens.
      if (dto.isActive === false) {
        await this.authService.revokeAllForUser(id, tx);
      }

      const after = UsersService.toDto(user);
      await writeAudit(tx, actor, {
        action: 'UPDATE',
        entityType: 'User',
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
    const passwordHash = await hashPassword(dto.temporaryPassword);

    return this.prisma.$transaction(async (tx) => {
      await tx.$executeRaw`SELECT pg_advisory_xact_lock(${ADMIN_SET_LOCK})`;
      await UsersService.assertNotDeleted(tx, id);
      const user = await tx.user.update({
        where: { id },
        data: { passwordHash, mustChangePassword: true },
        include: USER_ACCESS_INCLUDE,
      });

      const revoked = await this.authService.revokeAllForUser(id, tx);

      // Le mot de passe lui-même n'apparaît JAMAIS dans le journal : on ne trace
      // que le fait qu'une réinitialisation a eu lieu.
      await writeAudit(tx, actor, {
        action: 'UPDATE',
        entityType: 'User',
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
  ): Promise<RevokedSessionsDto> {
    await this.findOne(id);

    return this.prisma.$transaction(async (tx) => {
      const revoked = await this.authService.revokeAllForUser(id, tx);
      await writeAudit(tx, actor, {
        action: 'UPDATE',
        entityType: 'User',
        entityId: id,
        newValue: { operation: 'REVOKE_SESSIONS', revokedSessions: revoked },
      });
      return { revoked };
    });
  }

  /// SUPPRESSION d'un compte (2026-10-07). L'historique le désigne (ventes,
  /// mouvements, audit) : il n'est donc pas effacé (règle 7) mais archivé —
  /// inactif, sans rôle, sessions coupées, email/téléphone libérés pour un
  /// autre compte, absent de la liste. Irréversible depuis l'app : on recrée
  /// un compte. Mêmes gardes que la désactivation : jamais soi-même, jamais le
  /// dernier administrateur actif. Rejouée, elle ne refait rien.
  async remove(id: string, actor: ActorContext): Promise<void> {
    if (actor.userId?.toLowerCase() === id.toLowerCase()) {
      throw new BusinessException(
        ErrorCode.SELF_MODIFICATION_FORBIDDEN,
        'Votre propre compte est supprimé par un autre administrateur',
        HttpStatus.FORBIDDEN,
      );
    }
    await this.prisma.$transaction(async (tx) => {
      await tx.$executeRaw`SELECT pg_advisory_xact_lock(${ADMIN_SET_LOCK})`;
      const before = await this.findOne(id, tx);
      const row = await tx.user.findUniqueOrThrow({
        where: { id },
        select: { deletedAt: true },
      });
      if (row.deletedAt) return;

      if (before.isActive && before.roles.includes(RoleCode.ADMIN)) {
        const remainingAdmins = await tx.user.count({
          where: {
            isActive: true,
            roles: { some: { code: RoleCode.ADMIN } },
            NOT: { id },
          },
        });
        if (remainingAdmins === 0) {
          throw new BusinessException(
            ErrorCode.LAST_ACTIVE_ADMIN,
            'Impossible : ce compte est le dernier administrateur actif',
            HttpStatus.CONFLICT,
          );
        }
      }

      await tx.user.update({
        where: { id },
        data: {
          deletedAt: new Date(),
          isActive: false,
          email: null,
          phone: null,
          roles: { set: [] },
          permissions: { set: [] },
        },
      });
      const revoked = await this.authService.revokeAllForUser(id, tx);
      await writeAudit(tx, actor, {
        action: 'CANCEL',
        entityType: 'User',
        entityId: id,
        oldValue: UsersService.auditSnapshot(before),
        newValue: { operation: 'DELETE', revokedSessions: revoked },
      });
    });
  }

  /// Un compte supprimé ne se modifie plus (ni réactivation, ni mot de passe).
  private static async assertNotDeleted(db: Db, id: string): Promise<void> {
    const row = await db.user.findUnique({
      where: { id },
      select: { deletedAt: true },
    });
    if (row?.deletedAt) {
      throw new BusinessException(
        ErrorCode.INVALID_STATE_TRANSITION,
        'Ce compte a été supprimé : créez-en un nouveau',
        HttpStatus.CONFLICT,
      );
    }
  }

  /// Unicité des identifiants de connexion. L'email est comparé sans casse (les
  /// comptes antérieurs à la normalisation peuvent en porter). Une course entre
  /// deux créations simultanées reste arrêtée par la contrainte d'unicité (409).
  private async assertIdentifiersFree(
    db: Db,
    email?: string,
    phone?: string,
    exceptUserId?: string,
  ): Promise<void> {
    const clauses: Prisma.UserWhereInput[] = [
      ...(email
        ? [{ email: { equals: email, mode: 'insensitive' as const } }]
        : []),
      ...(phone ? [{ phone }] : []),
    ];
    if (clauses.length === 0) return;

    const existing = await db.user.findFirst({
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
