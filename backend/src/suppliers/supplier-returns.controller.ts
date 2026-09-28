import {
  Body,
  Controller,
  Get,
  Ip,
  Param,
  Post,
  StreamableFile,
} from '@nestjs/common';
import {
  ApiBearerAuth,
  ApiCreatedResponse,
  ApiOkResponse,
  ApiOperation,
  ApiProduces,
  ApiTags,
} from '@nestjs/swagger';
import { Throttle } from '@nestjs/throttler';
import {
  AuthenticatedUser,
  CurrentUser,
  RequirePermissions,
  RoleCode,
  Roles,
} from '../common/auth.decorators';
import { CanonicalUuidPipe } from '../common/canonical-uuid.pipe';
import { PERMISSIONS } from '../common/permissions';
import {
  CreateSupplierReturnDto,
  SupplierReturnDto,
} from './dto/supplier-return.dto';
import { SupplierReturnsService } from './supplier-returns.service';

/// Mêmes gardes que la RÉCEPTION (ADMIN|MAGASINIER + `reception.create`) :
/// c'est son opération inverse — la dette fournisseur baisse du TTC renvoyé.
@ApiTags('Fournisseurs')
@ApiBearerAuth()
@Controller()
@Roles(RoleCode.ADMIN, RoleCode.MAGASINIER)
@RequirePermissions(PERMISSIONS.RECEPTION_CREATE)
export class SupplierReturnsController {
  constructor(private readonly returns: SupplierReturnsService) {}

  @Post('supplier-returns')
  @ApiOperation({
    summary: 'Retour fournisseur : stock sortant, dette réduite, bon RF',
  })
  @ApiCreatedResponse({ type: SupplierReturnDto })
  create(
    @Body() dto: CreateSupplierReturnDto,
    @CurrentUser() user: AuthenticatedUser,
    @Ip() ip: string,
  ): Promise<SupplierReturnDto> {
    return this.returns.create(dto, user, { userId: user.id, ipAddress: ip });
  }

  @Get('suppliers/:id/returns')
  @ApiOperation({ summary: 'Retours à un fournisseur (200 plus récents)' })
  @ApiOkResponse({ type: [SupplierReturnDto] })
  list(
    @Param('id', CanonicalUuidPipe) id: string,
  ): Promise<SupplierReturnDto[]> {
    return this.returns.forSupplier(id);
  }

  @Get('supplier-returns/:id/pdf')
  @Throttle({ default: { ttl: 60_000, limit: 30 } })
  @ApiOperation({ summary: 'Bon de retour fournisseur (PDF)' })
  @ApiProduces('application/pdf')
  @ApiOkResponse({ schema: { type: 'string', format: 'binary' } })
  async document(
    @Param('id', CanonicalUuidPipe) id: string,
  ): Promise<StreamableFile> {
    const { filename, pdf } = await this.returns.renderDocument(id);
    return new StreamableFile(pdf, {
      type: 'application/pdf',
      disposition: `inline; filename="${filename}"`,
    });
  }
}
