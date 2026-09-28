import { Injectable } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { ActorContext, writeAudit } from '../audit/audit-writer';
import { PrismaService } from '../prisma/prisma.service';
import {
  StoreSettingsDto,
  UpdateStoreSettingsDto,
} from './dto/store-settings.dto';
import { STORE_FIELDS, storeSettings } from './store-settings';

/// Identifiant fixe de la ligne unique dans le journal (colonne UUID).
const STORE_SETTINGS_AUDIT_ID = '00000000-0000-7000-8000-000000000001';

/// Paramètres du magasin (P1 bis n°21h). La lecture des valeurs effectives
/// (base, sinon env) est `storeSettings` : une seule règle, partagée avec
/// l'impression des documents.
@Injectable()
export class SettingsService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly config: ConfigService,
  ) {}

  store(): Promise<StoreSettingsDto> {
    return storeSettings(this.prisma, this.config);
  }

  /// Seuls les champs envoyés changent ; rien de changé : rien d'écrit, pas
  /// d'audit. Ligne verrouillée : deux enregistrements simultanés auditent
  /// chacun le vrai « avant ».
  async updateStore(
    dto: UpdateStoreSettingsDto,
    actor: ActorContext,
  ): Promise<StoreSettingsDto> {
    return this.prisma.$transaction(async (tx) => {
      await tx.$queryRaw`SELECT "id" FROM "StoreSettings" WHERE "id" = 1 FOR UPDATE`;
      const before = await storeSettings(tx, this.config);
      const data = Object.fromEntries(
        STORE_FIELDS.filter((f) => dto[f] !== undefined).map((f) => [
          f,
          dto[f],
        ]),
      );
      if (Object.keys(data).length === 0) return before;
      await tx.storeSettings.upsert({
        where: { id: 1 },
        create: { id: 1, ...data },
        update: data,
      });
      const after = await storeSettings(tx, this.config);
      if (JSON.stringify(before) !== JSON.stringify(after)) {
        await writeAudit(tx, actor, {
          action: 'UPDATE',
          entityType: 'StoreSettings',
          entityId: STORE_SETTINGS_AUDIT_ID,
          oldValue: { ...before },
          newValue: { ...after },
        });
      }
      return after;
    });
  }
}
