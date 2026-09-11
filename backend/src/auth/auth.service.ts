import { HttpStatus, Injectable, Logger } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { JwtService } from '@nestjs/jwt';
import { createHash, randomBytes } from 'node:crypto';
import { ActorContext, writeAudit } from '../audit/audit-writer';
import { BusinessException } from '../common/business.exception';
import { ErrorCode } from '../common/error-codes';
import { isEmailIdentifier } from '../common/identifiers';
import { AccessTokenPayload } from '../common/jwt-access.guard';
import {
  resolvePermissions,
  USER_ACCESS_INCLUDE,
  UserWithAccess,
} from '../common/user-access';
import { Prisma } from '../generated/prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import {
  AuthUserDto,
  ChangePasswordDto,
  LoginDto,
  LoginResponseDto,
  LogoutDto,
  LogoutResponseDto,
  TokensDto,
} from './dto/auth.dto';
import { hashPassword, verifyPassword } from './password';

/// Appareil auquel rattacher une session (révocation ciblée, téléphone volé).
interface DeviceInfo {
  deviceId?: string | null;
  deviceName?: string | null;
}

type Db = Prisma.TransactionClient;

@Injectable()
export class AuthService {
  private readonly logger = new Logger(AuthService.name);

  constructor(
    private readonly prisma: PrismaService,
    private readonly jwt: JwtService,
    private readonly config: ConfigService,
  ) {}

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

  private static accountDisabled(): BusinessException {
    return new BusinessException(
      ErrorCode.ACCOUNT_DISABLED,
      'Ce compte est désactivé',
      HttpStatus.FORBIDDEN,
    );
  }

  private static toAuthUser(user: UserWithAccess): AuthUserDto {
    return {
      id: user.id,
      email: user.email,
      phone: user.phone,
      fullName: user.fullName,
      roles: user.roles.map((role) => role.code),
      permissions: resolvePermissions(user),
      mustChangePassword: user.mustChangePassword,
    };
  }

  /// SEUL point d'émission de tokens du système.
  ///
  /// Refuse un compte désactivé quel que soit l'appelant : un futur chemin qui
  /// oublierait le contrôle ne pourrait pas, pour autant, rendre l'accès à un
  /// compte fermé (défense en profondeur — audit C1).
  private async issueTokens(
    db: Db,
    user: UserWithAccess,
    device: DeviceInfo = {},
  ): Promise<TokensDto> {
    if (!user.isActive) {
      throw AuthService.accountDisabled();
    }

    // La session est créée D'ABORD : l'access token porte son id (`sid`), ce qui
    // permet aux routes sensibles de refuser un token dont la session a été
    // révoquée entre-temps (contre-audit N1).
    const refreshToken = randomBytes(32).toString('hex');
    const expiresAt = new Date(
      Date.now() + this.refreshTtlDays() * 24 * 60 * 60 * 1000,
    );
    const session = await db.refreshToken.create({
      data: {
        userId: user.id,
        tokenHash: AuthService.hashRefreshToken(refreshToken),
        deviceId: device.deviceId ?? null,
        deviceName: device.deviceName ?? null,
        expiresAt,
      },
      select: { id: true },
    });

    const payload: AccessTokenPayload = {
      sub: user.id,
      sid: session.id,
      roles: user.roles.map((role) => role.code),
      permissions: resolvePermissions(user),
      mustChangePassword: user.mustChangePassword,
    };
    const accessToken = await this.jwt.signAsync(payload, {
      expiresIn: this.accessTtlSeconds(),
    });

    return { accessToken, refreshToken, expiresIn: this.accessTtlSeconds() };
  }

  /// Hash factice servant à égaliser le temps de réponse quand le compte n'existe pas
  /// (sinon un attaquant distingue « compte inconnu » de « mot de passe faux » au chrono).
  private static dummyHash?: string;

  private static async equalizeTiming(): Promise<void> {
    AuthService.dummyHash ??= await hashPassword('hash-factice-anti-enumeration');
    await verifyPassword(AuthService.dummyHash, 'peu-importe');
  }

  /// L'identifiant arrive déjà normalisé (`LoginDto`). Sa forme dit quelle colonne
  /// interroger : un email contient `@`, un téléphone jamais — aucune ambiguïté.
  /// L'email est comparé sans casse pour les comptes créés avant la normalisation.
  private findByIdentifier(identifier: string): Promise<UserWithAccess | null> {
    return this.prisma.user.findFirst({
      where: isEmailIdentifier(identifier)
        ? { email: { equals: identifier, mode: 'insensitive' } }
        : { phone: identifier },
      include: USER_ACCESS_INCLUDE,
    });
  }

  async login(dto: LoginDto): Promise<LoginResponseDto> {
    const user = await this.findByIdentifier(dto.identifier);

    // Même erreur ET même temps de réponse qu'un mot de passe faux :
    // ne révéler ni par le message, ni par le chrono, quels comptes existent.
    if (!user) {
      await AuthService.equalizeTiming();
    }
    if (!user || !(await verifyPassword(user.passwordHash, dto.password))) {
      throw new BusinessException(
        ErrorCode.INVALID_CREDENTIALS,
        'Identifiant ou mot de passe incorrect',
        HttpStatus.UNAUTHORIZED,
      );
    }
    if (!user.isActive) {
      throw AuthService.accountDisabled();
    }

    const tokens = await this.prisma.$transaction(async (tx) => {
      // Une reconnexion depuis le même appareil remplace sa session précédente :
      // sinon chaque réinstallation laisserait une session orpheline valide 90 j.
      if (dto.deviceId) {
        await tx.refreshToken.updateMany({
          where: { userId: user.id, deviceId: dto.deviceId, revokedAt: null },
          data: { revokedAt: new Date() },
        });
      }
      const issued = await this.issueTokens(tx, user, dto);
      await tx.user.update({
        where: { id: user.id },
        data: { lastLoginAt: new Date() },
      });
      return issued;
    });

    return { ...tokens, user: AuthService.toAuthUser(user) };
  }

  /// Rotation : le refresh présenté est révoqué et remplacé à chaque appel.
  async refresh(refreshToken: string, ipAddress?: string): Promise<LoginResponseDto> {
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
      return this.handleReuse(stored.userId, ipAddress);
    }
    if (stored.expiresAt.getTime() <= Date.now()) {
      throw new BusinessException(
        ErrorCode.REFRESH_TOKEN_EXPIRED,
        'Refresh token expiré, reconnexion nécessaire',
        HttpStatus.UNAUTHORIZED,
      );
    }

    const user = await this.prisma.user.findUnique({
      where: { id: stored.userId },
      include: USER_ACCESS_INCLUDE,
    });
    if (!user || !user.isActive) {
      await this.revokeAllForUser(stored.userId);
      throw AuthService.accountDisabled();
    }

    const tokens = await this.prisma.$transaction(async (tx) => {
      // Révocation ATOMIQUE : `revokedAt: null` dans le WHERE fait de cet update le
      // point de sérialisation. Deux refresh concurrents avec le même token → un seul
      // gagne (count === 1), l'autre voit count === 0 et est traité comme un rejeu.
      const claimed = await tx.refreshToken.updateMany({
        where: { id: stored.id, revokedAt: null },
        data: { revokedAt: new Date(), lastUsedAt: new Date() },
      });
      if (claimed.count === 0) return null;
      return this.issueTokens(tx, user, stored);
    });
    if (!tokens) {
      return this.handleReuse(stored.userId, ipAddress);
    }
    return { ...tokens, user: AuthService.toAuthUser(user) };
  }

  /// Réaction à un refresh token rejoué : toutes les sessions tombent, et la
  /// détection est TRACÉE — l'admin doit pouvoir voir qu'un vol a été présumé.
  private async handleReuse(userId: string, ipAddress?: string): Promise<never> {
    const revoked = await this.prisma.$transaction(async (tx) => {
      const count = await this.revokeAllForUser(userId, tx);
      await writeAudit(
        tx,
        { userId: null, ipAddress },
        {
          action: 'UPDATE',
          entityType: 'User',
          entityId: userId,
          newValue: { operation: 'REFRESH_TOKEN_REUSE_DETECTED', revokedSessions: count },
        },
      );
      return count;
    });
    this.logger.warn(
      `Refresh token rejoué pour ${userId} (IP ${ipAddress ?? '?'}) — ${revoked} session(s) fermée(s)`,
    );
    throw new BusinessException(
      ErrorCode.REFRESH_TOKEN_REVOKED,
      'Refresh token révoqué — toutes les sessions ont été fermées',
      HttpStatus.UNAUTHORIZED,
    );
  }

  /// Ferme la session portée par ce refresh token, ou TOUTES celles de son
  /// titulaire (`allDevices`). Le token est la preuve de possession (route publique).
  ///
  /// - Session seule : idempotent — un token inconnu ou déjà fermé rend `{ revoked: 0 }`.
  /// - `allDevices` : exige une session VALIDE. Sinon, un token volé puis révoqué
  ///   (ou simplement expiré) permettrait de déconnecter indéfiniment la victime,
  ///   et l'audit attribuerait l'action à la victime elle-même (contre-audit N3).
  ///   Un token révoqué est traité comme un rejeu : sessions fermées ET vol tracé.
  async logout(dto: LogoutDto, ipAddress?: string): Promise<LogoutResponseDto> {
    const stored = await this.prisma.refreshToken.findUnique({
      where: { tokenHash: AuthService.hashRefreshToken(dto.refreshToken) },
      select: { id: true, userId: true, revokedAt: true, expiresAt: true },
    });

    if (!dto.allDevices) {
      if (!stored) return { revoked: 0 };
      const result = await this.prisma.refreshToken.updateMany({
        where: { id: stored.id, revokedAt: null },
        data: { revokedAt: new Date() },
      });
      return { revoked: result.count };
    }

    if (!stored) {
      throw new BusinessException(
        ErrorCode.REFRESH_TOKEN_INVALID,
        'Session inconnue — aucune session fermée',
        HttpStatus.UNAUTHORIZED,
      );
    }
    if (stored.revokedAt) {
      return this.handleReuse(stored.userId, ipAddress);
    }
    if (stored.expiresAt.getTime() <= Date.now()) {
      throw new BusinessException(
        ErrorCode.REFRESH_TOKEN_EXPIRED,
        'Session expirée — aucune session fermée',
        HttpStatus.UNAUTHORIZED,
      );
    }

    const revoked = await this.prisma.$transaction(async (tx) => {
      const count = await this.revokeAllForUser(stored.userId, tx);
      await writeAudit(
        tx,
        { userId: stored.userId, ipAddress },
        {
          action: 'UPDATE',
          entityType: 'User',
          entityId: stored.userId,
          newValue: {
            operation: 'LOGOUT_ALL_DEVICES',
            revokedSessions: count,
            refreshTokenId: stored.id,
          },
        },
      );
      return count;
    });
    return { revoked };
  }

  /// Révoque toutes les sessions actives d'un compte. Accepte la transaction de
  /// l'appelant : une révocation qui fait partie d'une mutation plus large
  /// (désactivation, reset) doit réussir ou échouer AVEC elle.
  async revokeAllForUser(userId: string, db: Db = this.prisma): Promise<number> {
    const result = await db.refreshToken.updateMany({
      where: { userId, revokedAt: null },
      data: { revokedAt: new Date() },
    });
    return result.count;
  }

  /// Change le mot de passe, lève `mustChangePassword`, ferme toutes les sessions
  /// existantes et rend un couple de tokens neuf (l'appelant reste connecté).
  /// Tout ou rien, et tracé : un changement sans révocation laisserait vivre les
  /// sessions d'un éventuel voleur.
  async changePassword(
    userId: string,
    dto: ChangePasswordDto,
    actor: ActorContext,
  ): Promise<LoginResponseDto> {
    const user = await this.prisma.user.findUnique({
      where: { id: userId },
      include: USER_ACCESS_INCLUDE,
    });
    if (!user) {
      throw new BusinessException(
        ErrorCode.NOT_FOUND,
        'Utilisateur introuvable',
        HttpStatus.NOT_FOUND,
      );
    }
    // Un compte désactivé qui détient encore un access token (≤ 15 min) ne doit
    // pas pouvoir s'en servir pour obtenir des tokens neufs — audit C1.
    if (!user.isActive) {
      await this.revokeAllForUser(userId);
      throw AuthService.accountDisabled();
    }
    if (!(await verifyPassword(user.passwordHash, dto.currentPassword))) {
      throw new BusinessException(
        ErrorCode.CURRENT_PASSWORD_INVALID,
        'Mot de passe actuel incorrect',
        HttpStatus.FORBIDDEN,
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

    const passwordHash = await hashPassword(dto.newPassword);
    const updated = { ...user, passwordHash, mustChangePassword: false };

    const tokens = await this.prisma.$transaction(async (tx) => {
      // Compare-and-swap : l'écriture n'a lieu que si le mot de passe VÉRIFIÉ
      // ci-dessus est toujours celui en base, et le compte toujours actif. Sinon un
      // reset par l'admin (compte compromis) commité pendant le hachage serait
      // écrasé par le mot de passe de l'attaquant (contre-audit N4).
      const written = await tx.user.updateMany({
        where: { id: userId, isActive: true, passwordHash: user.passwordHash },
        data: { passwordHash, mustChangePassword: false },
      });
      if (written.count === 0) {
        throw new BusinessException(
          ErrorCode.CONFLICT,
          'Le mot de passe de ce compte a été modifié entre-temps — reconnectez-vous',
          HttpStatus.CONFLICT,
        );
      }
      const revoked = await this.revokeAllForUser(userId, tx);
      const issued = await this.issueTokens(tx, updated, dto);
      // Le mot de passe n'apparaît JAMAIS dans le journal : seul le fait est tracé.
      await writeAudit(tx, actor, {
        action: 'UPDATE',
        entityType: 'User',
        entityId: userId,
        newValue: {
          operation: 'PASSWORD_CHANGE',
          wasTemporary: user.mustChangePassword,
          revokedSessions: revoked,
        },
      });
      return issued;
    });

    return { ...tokens, user: AuthService.toAuthUser(updated) };
  }

  async me(userId: string): Promise<AuthUserDto> {
    const user = await this.prisma.user.findUnique({
      where: { id: userId },
      include: USER_ACCESS_INCLUDE,
    });
    if (!user) {
      throw new BusinessException(
        ErrorCode.NOT_FOUND,
        'Utilisateur introuvable',
        HttpStatus.NOT_FOUND,
      );
    }
    // L'app interroge /auth/me au démarrage : un compte désactivé y est détecté
    // sans attendre l'expiration de son access token.
    if (!user.isActive) {
      throw AuthService.accountDisabled();
    }
    return AuthService.toAuthUser(user);
  }
}
