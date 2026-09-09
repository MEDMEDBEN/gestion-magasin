import { HttpStatus, Injectable } from '@nestjs/common';
import { AuthService } from '../auth/auth.service';
import { RoleCode } from '../common/auth.decorators';
import { BusinessException } from '../common/business.exception';
import { PaginationQueryDto } from '../common/dto/pagination.dto';
import { ErrorCode } from '../common/error-codes';
import { PrismaService } from '../prisma/prisma.service';
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

  /// Création par l'admin uniquement (pas d'inscription publique) :
  /// le mot de passe fourni est TEMPORAIRE, `mustChangePassword` est forcé à vrai.
  async create(dto: CreateUserDto): Promise<UserDto> {
    if (!dto.email && !dto.phone) {
      throw new BusinessException(
        ErrorCode.VALIDATION_FAILED,
        'Fournir au moins un email ou un téléphone',
      );
    }
    await this.assertIdentifiersFree(dto.email, dto.phone);

    const user = (await this.prisma.user.create({
      data: {
        email: dto.email ?? null,
        phone: dto.phone ?? null,
        fullName: dto.fullName,
        passwordHash: await AuthService.hashPassword(dto.temporaryPassword),
        mustChangePassword: true,
        roles: { connect: dto.roles.map((code) => ({ code })) },
        permissions: dto.extraPermissions?.length
          ? { connect: dto.extraPermissions.map((code) => ({ code })) }
          : undefined,
      },
      include: UsersService.INCLUDE,
    })) as UserRow;

    return UsersService.toDto(user);
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

  async update(id: string, dto: UpdateUserDto): Promise<UserDto> {
    const current = await this.findOne(id);
    await this.assertIdentifiersFree(dto.email, dto.phone, id);

    // Filet de sécurité : ne jamais laisser le système sans aucun admin actif,
    // sinon plus personne ne peut administrer (seule sortie = intervention en base).
    const losesAdmin =
      current.roles.includes(RoleCode.ADMIN) &&
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

    const user = (await this.prisma.user.update({
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
    if (dto.isActive === false) {
      await this.authService.revokeAllForUser(id);
    }
    return UsersService.toDto(user);
  }

  /// Réinitialisation par l'admin : nouveau mot de passe temporaire, sessions coupées.
  async resetPassword(id: string, dto: ResetPasswordDto): Promise<UserDto> {
    await this.findOne(id);
    const user = (await this.prisma.user.update({
      where: { id },
      data: {
        passwordHash: await AuthService.hashPassword(dto.temporaryPassword),
        mustChangePassword: true,
      },
      include: UsersService.INCLUDE,
    })) as UserRow;
    await this.authService.revokeAllForUser(id);
    return UsersService.toDto(user);
  }

  async revokeSessions(id: string): Promise<{ revoked: number }> {
    await this.findOne(id);
    return { revoked: await this.authService.revokeAllForUser(id) };
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
