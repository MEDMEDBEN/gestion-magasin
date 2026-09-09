import { HttpStatus, Injectable } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { JwtService } from '@nestjs/jwt';
import * as argon2 from 'argon2';
import { createHash, randomBytes } from 'node:crypto';
import { BusinessException } from '../common/business.exception';
import { ErrorCode } from '../common/error-codes';
import { AccessTokenPayload } from '../common/jwt-access.guard';
import { PrismaService } from '../prisma/prisma.service';
import {
  AuthUserDto,
  ChangePasswordDto,
  LoginDto,
  LoginResponseDto,
  TokensDto,
} from './dto/auth.dto';

/// Utilisateur + rôles + permissions, tel que chargé pour construire un token.
type UserWithAccess = {
  id: string;
  email: string | null;
  phone: string | null;
  fullName: string;
  passwordHash: string;
  isActive: boolean;
  mustChangePassword: boolean;
  roles: { code: string; permissions: { code: string }[] }[];
  permissions: { code: string }[];
};

@Injectable()
export class AuthService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly jwt: JwtService,
    private readonly config: ConfigService,
  ) {}

  private static readonly USER_ACCESS_INCLUDE = {
    roles: { include: { permissions: { select: { code: true } } } },
    permissions: { select: { code: true } },
  } as const;

  /// argon2id : paramètres par défaut de la lib (déjà conformes aux recommandations OWASP).
  static hashPassword(plain: string): Promise<string> {
    return argon2.hash(plain, { type: argon2.argon2id });
  }

  static verifyPassword(hash: string, plain: string): Promise<boolean> {
    return argon2.verify(hash, plain).catch(() => false);
  }

  /// Le refresh token est opaque (256 bits aléatoires) et n'est stocké que sous forme de
  /// SHA-256. Un hash déterministe est nécessaire pour retrouver la ligne ; argon2 (salé)
  /// ne le permettrait pas. Sans risque ici : le secret est aléatoire, pas devinable.
  private static hashRefreshToken(token: string): string {
    return createHash('sha256').update(token).digest('hex');
  }

  private refreshTtlDays(): number {
    return Number(this.config.get('JWT_REFRESH_EXPIRES_DAYS') ?? 90);
  }

  private accessTtlSeconds(): number {
    return Number(this.config.get('JWT_ACCESS_EXPIRES_SECONDS') ?? 900);
  }

  private static resolvePermissions(user: UserWithAccess): string[] {
    const fromRoles = user.roles.flatMap((role) =>
      role.permissions.map((permission) => permission.code),
    );
    const direct = user.permissions.map((permission) => permission.code);
    return [...new Set([...fromRoles, ...direct])].sort();
  }

  private toAuthUser(user: UserWithAccess): AuthUserDto {
    return {
      id: user.id,
      email: user.email,
      phone: user.phone,
      fullName: user.fullName,
      roles: user.roles.map((role) => role.code),
      permissions: AuthService.resolvePermissions(user),
      mustChangePassword: user.mustChangePassword,
    };
  }

  private async issueTokens(
    user: UserWithAccess,
    device?: { deviceId?: string; deviceName?: string },
  ): Promise<TokensDto> {
    const payload: AccessTokenPayload = {
      sub: user.id,
      roles: user.roles.map((role) => role.code),
      permissions: AuthService.resolvePermissions(user),
      mustChangePassword: user.mustChangePassword,
    };
    const accessToken = await this.jwt.signAsync(payload, {
      expiresIn: this.accessTtlSeconds(),
    });

    const refreshToken = randomBytes(32).toString('hex');
    const expiresAt = new Date(
      Date.now() + this.refreshTtlDays() * 24 * 60 * 60 * 1000,
    );
    await this.prisma.refreshToken.create({
      data: {
        userId: user.id,
        tokenHash: AuthService.hashRefreshToken(refreshToken),
        deviceId: device?.deviceId ?? null,
        deviceName: device?.deviceName ?? null,
        expiresAt,
      },
    });

    return { accessToken, refreshToken, expiresIn: this.accessTtlSeconds() };
  }

  /// Hash factice servant à égaliser le temps de réponse quand le compte n'existe pas
  /// (sinon un attaquant distingue « compte inconnu » de « mot de passe faux » au chrono).
  private static dummyHash?: string;

  private static async equalizeTiming(): Promise<void> {
    AuthService.dummyHash ??= await AuthService.hashPassword(
      'hash-factice-anti-enumeration',
    );
    await AuthService.verifyPassword(AuthService.dummyHash, 'peu-importe');
  }

  async login(dto: LoginDto): Promise<LoginResponseDto> {
    const user = (await this.prisma.user.findFirst({
      where: {
        OR: [{ email: dto.identifier }, { phone: dto.identifier }],
      },
      include: AuthService.USER_ACCESS_INCLUDE,
    })) as UserWithAccess | null;

    // Même erreur ET même temps de réponse qu'un mot de passe faux :
    // ne révéler ni par le message, ni par le chrono, quels comptes existent.
    if (!user) {
      await AuthService.equalizeTiming();
    }
    if (!user || !(await AuthService.verifyPassword(user.passwordHash, dto.password))) {
      throw new BusinessException(
        ErrorCode.INVALID_CREDENTIALS,
        'Identifiant ou mot de passe incorrect',
        HttpStatus.UNAUTHORIZED,
      );
    }
    if (!user.isActive) {
      throw new BusinessException(
        ErrorCode.ACCOUNT_DISABLED,
        'Ce compte est désactivé',
        HttpStatus.FORBIDDEN,
      );
    }

    const tokens = await this.issueTokens(user, dto);
    await this.prisma.user.update({
      where: { id: user.id },
      data: { lastLoginAt: new Date() },
    });

    return { ...tokens, user: this.toAuthUser(user) };
  }

  /// Rotation : le refresh présenté est révoqué et remplacé à chaque appel.
  async refresh(refreshToken: string): Promise<LoginResponseDto> {
    const tokenHash = AuthService.hashRefreshToken(refreshToken);
    const stored = await this.prisma.refreshToken.findUnique({
      where: { tokenHash },
    });

    if (!stored) {
      throw new BusinessException(
        ErrorCode.REFRESH_TOKEN_INVALID,
        'Refresh token inconnu',
        HttpStatus.UNAUTHORIZED,
      );
    }
    if (stored.revokedAt) {
      // Un token déjà révoqué qui resurgit = vol probable → on coupe toutes les sessions.
      await this.revokeAllForUser(stored.userId);
      throw new BusinessException(
        ErrorCode.REFRESH_TOKEN_REVOKED,
        'Refresh token révoqué — toutes les sessions ont été fermées',
        HttpStatus.UNAUTHORIZED,
      );
    }
    if (stored.expiresAt.getTime() <= Date.now()) {
      throw new BusinessException(
        ErrorCode.REFRESH_TOKEN_EXPIRED,
        'Refresh token expiré, reconnexion nécessaire',
        HttpStatus.UNAUTHORIZED,
      );
    }

    const user = (await this.prisma.user.findUnique({
      where: { id: stored.userId },
      include: AuthService.USER_ACCESS_INCLUDE,
    })) as UserWithAccess | null;
    if (!user || !user.isActive) {
      await this.revokeAllForUser(stored.userId);
      throw new BusinessException(
        ErrorCode.ACCOUNT_DISABLED,
        'Ce compte est désactivé',
        HttpStatus.FORBIDDEN,
      );
    }

    // Révocation ATOMIQUE : `revokedAt: null` dans le WHERE fait de cet update le
    // point de sérialisation. Deux refresh concurrents avec le même token → un seul
    // gagne (count === 1), l'autre voit count === 0 et est traité comme un rejeu.
    const claimed = await this.prisma.refreshToken.updateMany({
      where: { id: stored.id, revokedAt: null },
      data: { revokedAt: new Date(), lastUsedAt: new Date() },
    });
    if (claimed.count === 0) {
      await this.revokeAllForUser(stored.userId);
      throw new BusinessException(
        ErrorCode.REFRESH_TOKEN_REVOKED,
        'Refresh token révoqué — toutes les sessions ont été fermées',
        HttpStatus.UNAUTHORIZED,
      );
    }

    const tokens = await this.issueTokens(user, {
      deviceId: stored.deviceId ?? undefined,
      deviceName: stored.deviceName ?? undefined,
    });
    return { ...tokens, user: this.toAuthUser(user) };
  }

  async logout(
    userId: string,
    options: { refreshToken?: string; allDevices?: boolean },
  ): Promise<{ revoked: number }> {
    if (options.allDevices) {
      return { revoked: await this.revokeAllForUser(userId) };
    }
    if (!options.refreshToken) {
      throw new BusinessException(
        ErrorCode.REFRESH_TOKEN_INVALID,
        'Fournir refreshToken, ou allDevices=true',
        HttpStatus.BAD_REQUEST,
      );
    }
    const result = await this.prisma.refreshToken.updateMany({
      where: {
        tokenHash: AuthService.hashRefreshToken(options.refreshToken),
        userId,
        revokedAt: null,
      },
      data: { revokedAt: new Date() },
    });
    return { revoked: result.count };
  }

  async revokeAllForUser(userId: string): Promise<number> {
    const result = await this.prisma.refreshToken.updateMany({
      where: { userId, revokedAt: null },
      data: { revokedAt: new Date() },
    });
    return result.count;
  }

  /// Change le mot de passe, lève `mustChangePassword`, ferme toutes les sessions
  /// existantes et rend un couple de tokens neuf (l'appelant reste connecté).
  async changePassword(
    userId: string,
    dto: ChangePasswordDto,
  ): Promise<LoginResponseDto> {
    const user = (await this.prisma.user.findUnique({
      where: { id: userId },
      include: AuthService.USER_ACCESS_INCLUDE,
    })) as UserWithAccess | null;
    if (!user) {
      throw new BusinessException(
        ErrorCode.NOT_FOUND,
        'Utilisateur introuvable',
        HttpStatus.NOT_FOUND,
      );
    }
    if (!(await AuthService.verifyPassword(user.passwordHash, dto.currentPassword))) {
      throw new BusinessException(
        ErrorCode.INVALID_CREDENTIALS,
        'Mot de passe actuel incorrect',
        HttpStatus.UNAUTHORIZED,
      );
    }
    // Sans ceci, la première connexion pourrait « changer » le mot de passe temporaire
    // en le resoumettant à l'identique — le verrou mustChangePassword serait vide de sens.
    if (dto.newPassword === dto.currentPassword) {
      throw new BusinessException(
        ErrorCode.VALIDATION_FAILED,
        'Le nouveau mot de passe doit être différent de l’actuel',
      );
    }

    const passwordHash = await AuthService.hashPassword(dto.newPassword);
    await this.prisma.user.update({
      where: { id: userId },
      data: { passwordHash, mustChangePassword: false },
    });
    await this.revokeAllForUser(userId);

    const updated: UserWithAccess = {
      ...user,
      passwordHash,
      mustChangePassword: false,
    };
    const tokens = await this.issueTokens(updated);
    return { ...tokens, user: this.toAuthUser(updated) };
  }

  async me(userId: string): Promise<AuthUserDto> {
    const user = (await this.prisma.user.findUnique({
      where: { id: userId },
      include: AuthService.USER_ACCESS_INCLUDE,
    })) as UserWithAccess | null;
    if (!user) {
      throw new BusinessException(
        ErrorCode.NOT_FOUND,
        'Utilisateur introuvable',
        HttpStatus.NOT_FOUND,
      );
    }
    return this.toAuthUser(user);
  }
}
