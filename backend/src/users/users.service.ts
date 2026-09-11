import { HttpStatus, Injectable } from '@nestjs/common';
import { ActorContext, writeAudit } from '../audit/audit-writer';
import { AuthService } from '../auth/auth.service';
import { hashPassword } from '../auth/password';
import { RoleCode } from '../common/auth.decorators';
import { BusinessException } from '../common/business.exception';
import { PaginationQueryDto, parseSort } from '../common/dto/pagination.dto';
import { ErrorCode } from '../common/error-codes';
import {
  ADMIN_ONLY_PERMISSIONS,
  PERMISSION_DESCRIPTIONS,
  PERMISSIONS,
  ROLE_LABELS,
  ROLE_PERMISSIONS,
} from '../common/permissions';
import {
  resolvePermissions,
  USER_ACCESS_INCLUDE,
  UserWithAccess,
} from '../common/user-access';
import { Prisma } from '../generated/prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import {
  CreateUserDto,
  PermissionCatalogDto,
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
const ADMIN_SET_LOCK = 0x41444d494e; // « ADMIN »

const SORTABLE_FIELDS = ['fullName', 'email', 'createdAt', 'lastLoginAt'] as const;

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
      extraPermissions: user.permissions.map((p) => p.code).sort(),
      permissions: resolvePermissions(user),
      lastLoginAt: user.lastLoginAt,
      createdAt: user.createdAt,
    };
  }

  /// Instantané d'un compte destiné à `AuditLog`.
  ///
  /// Ne contient JAMAIS `passwordHash` ni un mot de passe en clair : le journal
  /// est consultable par l'admin et ne doit pas devenir une fuite de secrets.
  /// Les permissions accordées à la carte sont tracées À PART : c'est ce que la
  /// spec §24 appelle « changement de permission ».
  private static auditSnapshot(user: UserDto): Prisma.InputJsonValue {
    return {
      email: user.email,
      phone: user.phone,
      fullName: user.fullName,
      isActive: user.isActive,
      mustChangePassword: user.mustChangePassword,
      roles: user.roles,
      extraPermissions: user.extraPermissions,
      permissions: user.permissions,
    };
  }

  /// Catalogue des rôles et permissions, lu dans `permissions.ts` (source unique).
  permissionCatalog(): PermissionCatalogDto {
    return {
      roles: Object.values(RoleCode).map((code) => ({
        code,
        name: ROLE_LABELS[code],
        permissions: [...ROLE_PERMISSIONS[code]],
      })),
      permissions: Object.values(PERMISSIONS).map((code) => ({
        code,
        description: PERMISSION_DESCRIPTIONS[code],
        adminOnly: ADMIN_ONLY_PERMISSIONS.includes(code),
      })),
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
    UsersService.assertGrantable(dto.roles, dto.extraPermissions ?? []);
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
          permissions: dto.extraPermissions?.length
            ? { connect: dto.extraPermissions.map((code) => ({ code })) }
            : undefined,
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
    const where: Prisma.UserWhereInput = query.q
      ? {
          OR: [
            { fullName: { contains: query.q, mode: 'insensitive' } },
            { email: { contains: query.q, mode: 'insensitive' } },
            { phone: { contains: query.q } },
          ],
        }
      : {};
    const orderBy = parseSort(query.sort, SORTABLE_FIELDS, { createdAt: 'desc' });

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
    const touchesAccess =
      dto.roles !== undefined ||
      dto.extraPermissions !== undefined ||
      dto.isActive !== undefined;
    if (actor.userId === id && touchesAccess) {
      throw new BusinessException(
        ErrorCode.SELF_MODIFICATION_FORBIDDEN,
        'Vos rôles, permissions et activation sont modifiés par un autre administrateur',
        HttpStatus.FORBIDDEN,
      );
    }

    return this.prisma.$transaction(async (tx) => {
      if (touchesAccess) {
        await tx.$executeRawUnsafe(`SELECT pg_advisory_xact_lock(${ADMIN_SET_LOCK})`);
      }
      // Lu SOUS le verrou : l'« avant » de l'audit et le contrôle « dernier
      // admin » portent sur l'état réel, pas sur une lecture périmée.
      const before = await this.findOne(id, tx);
      await this.assertIdentifiersFree(tx, dto.email, dto.phone, id);

      const finalRoles = dto.roles ?? (before.roles as RoleCode[]);
      const finalExtra = dto.extraPermissions ?? before.extraPermissions;
      UsersService.assertGrantable(finalRoles, finalExtra);

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
          roles: dto.roles ? { set: dto.roles.map((code) => ({ code })) } : undefined,
          permissions: dto.extraPermissions
            ? { set: dto.extraPermissions.map((code) => ({ code })) }
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

  /// Règles fermes de `docs/permissions.md` : une permission réservée à l'ADMIN
  /// n'est jamais accordée à la carte à un compte qui n'est pas administrateur.
  /// Vérifié sur l'état FINAL (rôles + permissions après la mutation) : retirer
  /// le rôle ADMIN à un compte qui garde `price.manage` est refusé aussi.
  private static assertGrantable(
    roles: readonly string[],
    extraPermissions: readonly string[],
  ): void {
    if (roles.includes(RoleCode.ADMIN)) return;
    const forbidden = extraPermissions.filter((code) =>
      (ADMIN_ONLY_PERMISSIONS as readonly string[]).includes(code),
    );
    if (forbidden.length > 0) {
      throw new BusinessException(
        ErrorCode.PERMISSION_NOT_GRANTABLE,
        `Réservé à l'administrateur, non attribuable à ce compte : ${forbidden.join(', ')}`,
        HttpStatus.UNPROCESSABLE_ENTITY,
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
      ...(email ? [{ email: { equals: email, mode: 'insensitive' as const } }] : []),
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
