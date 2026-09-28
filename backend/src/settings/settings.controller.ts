import { Body, Controller, Get, Ip, Patch } from '@nestjs/common';
import {
  ApiBearerAuth,
  ApiOkResponse,
  ApiOperation,
  ApiTags,
} from '@nestjs/swagger';
import {
  AuthenticatedUser,
  CurrentUser,
  RequirePermissions,
  RoleCode,
  Roles,
} from '../common/auth.decorators';
import { PERMISSIONS } from '../common/permissions';
import {
  StoreSettingsDto,
  UpdateStoreSettingsDto,
} from './dto/store-settings.dto';
import { SettingsService } from './settings.service';

/// Paramètres (P1 bis n°21h) : identité du magasin imprimée sur les tickets,
/// factures, devis et bons. ADMIN + `settings.manage`, lecture comprise (les
/// documents, eux, la lisent côté serveur).
@ApiTags('Paramètres')
@ApiBearerAuth()
@Controller('settings')
@Roles(RoleCode.ADMIN)
@RequirePermissions(PERMISSIONS.SETTINGS_MANAGE)
export class SettingsController {
  constructor(private readonly settings: SettingsService) {}

  @Get('store')
  @ApiOperation({
    summary: 'Identité du magasin (valeurs effectives : base, sinon env)',
  })
  @ApiOkResponse({ type: StoreSettingsDto })
  store(): Promise<StoreSettingsDto> {
    return this.settings.store();
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
    return this.settings.updateStore(dto, { userId: user.id, ipAddress: ip });
  }
}
