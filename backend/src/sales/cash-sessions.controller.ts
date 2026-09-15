import {
  Body,
  Controller,
  Get,
  HttpCode,
  HttpStatus,
  Ip,
  Param,
  Post,
} from '@nestjs/common';
import {
  ApiBearerAuth,
  ApiConflictResponse,
  ApiCreatedResponse,
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
import { CanonicalUuidPipe } from '../common/canonical-uuid.pipe';
import { ErrorResponseDto } from '../common/dto/error-response.dto';
import { PERMISSIONS } from '../common/permissions';
import { CashSessionsService } from './cash-sessions.service';
import {
  CashSessionDto,
  CloseCashSessionDto,
  OpenCashSessionDto,
} from './dto/sale.dto';

@ApiTags('Caisse')
@ApiBearerAuth()
@Controller('cash-sessions')
export class CashSessionsController {
  constructor(private readonly cashSessions: CashSessionsService) {}

  @Roles(RoleCode.ADMIN, RoleCode.VENDEUR)
  @RequirePermissions(PERMISSIONS.CASH_SESSION_MANAGE)
  @Post()
  @ApiOperation({ summary: 'Ouvre SA caisse au magasin, avec un fond' })
  @ApiCreatedResponse({ type: CashSessionDto })
  @ApiConflictResponse({
    type: ErrorResponseDto,
    description: '`CASH_SESSION_ALREADY_OPEN`',
  })
  open(
    @Body() dto: OpenCashSessionDto,
    @CurrentUser() user: AuthenticatedUser,
    @Ip() ip: string,
  ): Promise<CashSessionDto> {
    return this.cashSessions.open(dto, user, {
      userId: user.id,
      ipAddress: ip,
    });
  }

  @Roles(RoleCode.ADMIN, RoleCode.VENDEUR)
  @RequirePermissions(PERMISSIONS.CASH_SESSION_MANAGE)
  @Get('current')
  @ApiOperation({
    summary: 'Caisse ouverte du compte connecté (null si aucune)',
  })
  @ApiOkResponse({ type: CashSessionDto })
  current(
    @CurrentUser() user: AuthenticatedUser,
  ): Promise<CashSessionDto | null> {
    return this.cashSessions.current(user);
  }

  @Roles(RoleCode.ADMIN, RoleCode.VENDEUR)
  @RequirePermissions(PERMISSIONS.CASH_SESSION_MANAGE)
  @Post(':id/close')
  @HttpCode(HttpStatus.OK)
  @ApiOperation({
    summary: 'Clôture la session et produit le rapport Z',
    description: 'Attendu = fond + ventes espèces ; écart = compté − attendu.',
  })
  @ApiOkResponse({ type: CashSessionDto })
  close(
    @Param('id', CanonicalUuidPipe) id: string,
    @Body() dto: CloseCashSessionDto,
    @CurrentUser() user: AuthenticatedUser,
    @Ip() ip: string,
  ): Promise<CashSessionDto> {
    return this.cashSessions.close(id, dto, user, {
      userId: user.id,
      ipAddress: ip,
    });
  }

  @Roles(RoleCode.ADMIN, RoleCode.VENDEUR)
  @RequirePermissions(PERMISSIONS.CASH_REPORT_READ)
  @Get(':id/report')
  @ApiOperation({ summary: 'Rapport Z (le vendeur : sa session seulement)' })
  @ApiOkResponse({ type: CashSessionDto })
  report(
    @Param('id', CanonicalUuidPipe) id: string,
    @CurrentUser() user: AuthenticatedUser,
  ): Promise<CashSessionDto> {
    return this.cashSessions.report(id, user);
  }
}
