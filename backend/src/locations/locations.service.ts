import { HttpStatus, Injectable } from '@nestjs/common';
import { ActorContext, writeAudit } from '../audit/audit-writer';
import { BusinessException } from '../common/business.exception';
import { ErrorCode } from '../common/error-codes';
import { Location, Prisma } from '../generated/prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import {
  CreateLocationDto,
  LocationDto,
  LocationTypeDto,
  UpdateLocationDto,
} from './dto/location.dto';

type Db = Prisma.TransactionClient;

/// Emplacements (spec §5 : Zone → Rayon → Étagère → Position).
/// MAGASIN, DEPOT et TRANSIT portent le stock et sont uniques (seed) : seules les
/// positions physiques du dépôt (EMPLACEMENT) se créent et se modifient ici.
@Injectable()
export class LocationsService {
  constructor(private readonly prisma: PrismaService) {}

  static toDto(location: Location): LocationDto {
    return {
      id: location.id,
      code: location.code,
      name: location.name,
      type: location.type as LocationTypeDto,
      parentId: location.parentId,
      zone: location.zone,
      aisle: location.aisle,
      shelf: location.shelf,
      position: location.position,
      isActive: location.isActive,
      updatedAt: location.updatedAt,
    };
  }

  async findAll(): Promise<LocationDto[]> {
    const rows = await this.prisma.location.findMany({
      orderBy: [{ type: 'asc' }, { code: 'asc' }],
    });
    return rows.map(LocationsService.toDto);
  }

  async create(
    dto: CreateLocationDto,
    actor: ActorContext,
  ): Promise<LocationDto> {
    if (dto.type && dto.type !== LocationTypeDto.EMPLACEMENT) {
      throw new BusinessException(
        ErrorCode.VALIDATION_FAILED,
        'Seuls les emplacements de dépôt se créent : magasin, dépôt et transit sont uniques',
        HttpStatus.UNPROCESSABLE_ENTITY,
      );
    }
    const parts = [dto.zone, dto.aisle, dto.shelf, dto.position];
    const code = dto.code ?? LocationsService.codeFrom(parts);
    if (!code || code.length > 40) {
      throw new BusinessException(
        ErrorCode.VALIDATION_FAILED,
        'Fournir un code (40 caractères max) ou au moins la zone',
        HttpStatus.UNPROCESSABLE_ENTITY,
      );
    }

    return this.prisma.$transaction(async (tx) => {
      const parent = await tx.location.findFirst({
        where: {
          type: 'DEPOT',
          isActive: true,
          ...(dto.parentId && { id: dto.parentId }),
        },
      });
      if (!parent) {
        throw new BusinessException(
          ErrorCode.VALIDATION_FAILED,
          'parentId : un emplacement se rattache à un dépôt actif',
          HttpStatus.UNPROCESSABLE_ENTITY,
        );
      }
      await LocationsService.assertCodeFree(tx, code);
      const location = await tx.location.create({
        data: {
          id: dto.id,
          code,
          name: dto.name ?? LocationsService.nameFrom(parts) ?? code,
          type: 'EMPLACEMENT',
          parentId: parent.id,
          zone: dto.zone ?? null,
          aisle: dto.aisle ?? null,
          shelf: dto.shelf ?? null,
          position: dto.position ?? null,
        },
      });
      const created = LocationsService.toDto(location);
      await writeAudit(tx, actor, {
        action: 'CREATE',
        entityType: 'Location',
        entityId: created.id,
        newValue: LocationsService.auditSnapshot(created),
      });
      return created;
    });
  }

  /// Seule écriture du catalogue ouverte à un autre rôle qu'ADMIN (MAGASINIER) :
  /// qui a recodé ou désactivé un emplacement doit rester traçable.
  async update(
    id: string,
    dto: UpdateLocationDto,
    actor: ActorContext,
  ): Promise<LocationDto> {
    return this.prisma.$transaction(async (tx) => {
      const before = await tx.location.findUnique({ where: { id } });
      if (!before) {
        throw new BusinessException(
          ErrorCode.NOT_FOUND,
          'Emplacement introuvable',
          HttpStatus.NOT_FOUND,
        );
      }
      if (before.type !== 'EMPLACEMENT') {
        throw new BusinessException(
          ErrorCode.VALIDATION_FAILED,
          'Magasin, dépôt et transit ne se modifient pas ici',
          HttpStatus.UNPROCESSABLE_ENTITY,
        );
      }
      if (dto.code !== undefined && dto.code !== before.code) {
        await LocationsService.assertCodeFree(tx, dto.code);
      }
      const location = await tx.location.update({
        where: { id },
        data: {
          ...(dto.code !== undefined && { code: dto.code }),
          ...(dto.name !== undefined && { name: dto.name }),
          ...(dto.zone !== undefined && { zone: dto.zone }),
          ...(dto.aisle !== undefined && { aisle: dto.aisle }),
          ...(dto.shelf !== undefined && { shelf: dto.shelf }),
          ...(dto.position !== undefined && { position: dto.position }),
          ...(dto.isActive !== undefined && { isActive: dto.isActive }),
        },
      });
      const after = LocationsService.toDto(location);
      const oldValue = LocationsService.auditSnapshot(
        LocationsService.toDto(before),
      );
      const newValue = LocationsService.auditSnapshot(after);
      if (JSON.stringify(oldValue) !== JSON.stringify(newValue)) {
        await writeAudit(tx, actor, {
          action: 'UPDATE',
          entityType: 'Location',
          entityId: id,
          oldValue,
          newValue,
        });
      }
      return after;
    });
  }

  private static auditSnapshot(location: LocationDto): Prisma.InputJsonObject {
    const snapshot: Partial<LocationDto> = { ...location };
    delete snapshot.updatedAt;
    return snapshot as Prisma.InputJsonObject;
  }

  /// `A-02-04-03` : les niveaux renseignés, dans l'ordre, jusqu'au premier absent.
  static codeFrom(parts: (string | null | undefined)[]): string | null {
    const present = LocationsService.leadingParts(parts);
    if (present.length === 0) return null;
    const code = present
      .join('-')
      .toUpperCase()
      .replace(/[^A-Z0-9._-]/g, '');
    return code || null;
  }

  static nameFrom(parts: (string | null | undefined)[]): string | null {
    const labels = ['Zone', 'Rayon', 'Étagère', 'Position'];
    const present = LocationsService.leadingParts(parts);
    return present.length
      ? present.map((part, i) => `${labels[i]} ${part}`).join(' · ')
      : null;
  }

  private static leadingParts(parts: (string | null | undefined)[]): string[] {
    const present: string[] = [];
    for (const part of parts) {
      if (!part) break;
      present.push(part);
    }
    return present;
  }

  private static async assertCodeFree(tx: Db, code: string) {
    const taken = await tx.location.findUnique({
      where: { code },
      select: { id: true },
    });
    if (taken) {
      throw new BusinessException(
        ErrorCode.CONFLICT,
        `Le code d’emplacement ${code} est déjà utilisé`,
        HttpStatus.CONFLICT,
      );
    }
  }
}
