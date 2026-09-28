import { Body, Controller, Get, Ip, Param, Post, Query } from '@nestjs/common';
import {
  ApiBearerAuth,
  ApiOkResponse,
  ApiOperation,
  ApiTags,
} from '@nestjs/swagger';
import {
  AuthenticatedUser,
  CurrentUser,
  RequireFreshAccess,
  RequirePermissions,
  RoleCode,
  Roles,
} from '../common/auth.decorators';
import { CanonicalUuidPipe } from '../common/canonical-uuid.pipe';
import {
  ChequeDto,
  ChequeListQueryDto,
  ChequeStatusDto,
} from '../common/dto/payment.dto';
import { PERMISSIONS } from '../common/permissions';
import { ChequesService } from './cheques.service';

/// Portefeuille de chèques (P1 bis n°21n) : ADMIN seul, avec les DEUX droits
/// de paiement — il porte les chèques des clients ET des fournisseurs. Le
/// vendeur SAISIT un chèque client par `POST /payments/customer` ; seul l'admin
/// statue (décision MEDMEDBEN 2026-09-28).
@ApiTags('Paiements')
@ApiBearerAuth()
@Controller('cheques')
@Roles(RoleCode.ADMIN)
@RequirePermissions(
  PERMISSIONS.CUSTOMER_PAYMENT_CREATE,
  PERMISSIONS.SUPPLIER_PAYMENT_CREATE,
)
export class ChequesController {
  constructor(private readonly cheques: ChequesService) {}

  @Get()
  @RequireFreshAccess()
  @ApiOperation({ summary: 'Chèques reçus et émis (filtre par statut)' })
  @ApiOkResponse({ type: [ChequeDto] })
  list(@Query() query: ChequeListQueryDto): Promise<ChequeDto[]> {
    return this.cheques.list(query);
  }

  @Post('customer/:id/status')
  @ApiOperation({
    summary: 'Chèque client encaissé ou rejeté (rejet : la dette revient)',
  })
  @ApiOkResponse({ type: ChequeDto })
  customer(
    @Param('id', CanonicalUuidPipe) id: string,
    @Body() dto: ChequeStatusDto,
    @CurrentUser() user: AuthenticatedUser,
    @Ip() ip: string,
  ): Promise<ChequeDto> {
    return this.cheques.setStatus('CLIENT', id, dto, user, {
      userId: user.id,
      ipAddress: ip,
    });
  }

  @Post('supplier/:id/status')
  @ApiOperation({
    summary: 'Chèque fournisseur débité ou rejeté (rejet : la dette revient)',
  })
  @ApiOkResponse({ type: ChequeDto })
  supplier(
    @Param('id', CanonicalUuidPipe) id: string,
    @Body() dto: ChequeStatusDto,
    @CurrentUser() user: AuthenticatedUser,
    @Ip() ip: string,
  ): Promise<ChequeDto> {
    return this.cheques.setStatus('FOURNISSEUR', id, dto, user, {
      userId: user.id,
      ipAddress: ip,
    });
  }
}
