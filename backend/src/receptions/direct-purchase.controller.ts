import { Body, Controller, Ip, Post } from '@nestjs/common';
import {
  ApiBearerAuth,
  ApiCreatedResponse,
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
  CreateDirectPurchaseDto,
  DirectPurchaseDto,
  DirectPurchaseService,
} from './direct-purchase';

@ApiTags('purchases')
@ApiBearerAuth()
@Controller('purchases')
export class DirectPurchaseController {
  constructor(private readonly purchases: DirectPurchaseService) {}

  /// Mêmes gardes qu'une réception ; payer (`paidAmount`) exige en plus
  /// ADMIN + supplier.payment.create (contrôlé dans la réception).
  @Roles(RoleCode.ADMIN, RoleCode.MAGASINIER)
  @RequirePermissions(PERMISSIONS.RECEPTION_CREATE)
  @Post('direct')
  @ApiOperation({
    summary: 'Achat direct : le panier entre en stock, le reste va en dette',
  })
  @ApiCreatedResponse({ type: DirectPurchaseDto })
  create(
    @Body() dto: CreateDirectPurchaseDto,
    @CurrentUser() user: AuthenticatedUser,
    @Ip() ip: string,
  ): Promise<DirectPurchaseDto> {
    return this.purchases.create(dto, user, { userId: user.id, ipAddress: ip });
  }
}
