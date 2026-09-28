import { Body, Controller, Get, Ip, Patch } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import {
  ApiBearerAuth,
  ApiOkResponse,
  ApiOperation,
  ApiTags,
} from '@nestjs/swagger';
import { writeAudit } from '../audit/audit-writer';
import {
  AuthenticatedUser,
  CurrentUser,
  RequirePermissions,
  RoleCode,
  Roles,
} from '../common/auth.decorators';
import { PERMISSIONS } from '../common/permissions';
import { PrismaService } from '../prisma/prisma.service';
import {
  StoreSettingsDto,
  UpdateStoreSettingsDto,
} from './dto/store-settings.dto';
import { STORE_FIELDS, storeSettings } from './store-settings';

/// Identifiant fixe de la ligne unique dans le journal (colonne UUID).
const STORE_SETTINGS_AUDIT_ID = '00000000-0000-7000-8000-000000000001';

/// Paramètres (P1 bis n°21h) : identité du magasin imprimée sur les tickets,
/// factures, devis et bons. ADMIN + `settings.manage`, lecture comprise (les
/// documents, eux, la lisent côté serveur).
@ApiTags('Paramètres')
@ApiBearerAuth()
@Controller('settings')
@Roles(RoleCode.ADMIN)
@RequirePermissions(PERMISSIONS.SETTINGS_MANAGE)
export class SettingsController {
  constructor(
    private readonly prisma: PrismaService,
    private readonly config: ConfigService,
  ) {}

  @Get('store')
  @ApiOperation({
    summary: 'Identité du magasin (valeurs effectives : base, sinon env)',
  })
  @ApiOkResponse({ type: StoreSettingsDto })
  store(): Promise<StoreSettingsDto> {
    return storeSettings(this.prisma, this.config);
  }

  @Patch('store')
  @ApiOperation({
    summary: 'Modifie l’identité du magasin (champ vide : retour à l’env)',
  })
  @ApiOkResponse({ type: StoreSettingsDto })
  update(
    @Body() dto: UpdateStoreSettingsDto,
    @CurrentUser() user: AuthenticatedUser,
    @Ip() ip: string,
  ): Promise<StoreSettingsDto> {
    return this.prisma.$transaction(async (tx) => {
      const before = await storeSettings(tx, this.config);
      const data = Object.fromEntries(
        STORE_FIELDS.filter((f) => dto[f] !== undefined).map((f) => [
          f,
          dto[f],
        ]),
      );
      await tx.storeSettings.upsert({
        where: { id: 1 },
        create: { id: 1, ...data },
        update: data,
      });
      const after = await storeSettings(tx, this.config);
      await writeAudit(
        tx,
        { userId: user.id, ipAddress: ip },
        {
          action: 'UPDATE',
          entityType: 'StoreSettings',
          entityId: STORE_SETTINGS_AUDIT_ID,
          oldValue: { ...before },
          newValue: { ...after },
        },
      );
      return after;
    });
  }
}
