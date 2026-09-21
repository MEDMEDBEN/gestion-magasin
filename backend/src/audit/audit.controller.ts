import { Controller, Get, Query } from '@nestjs/common';
import {
  ApiBearerAuth,
  ApiOkResponse,
  ApiOperation,
  ApiTags,
} from '@nestjs/swagger';
import {
  RequireFreshAccess,
  RequirePermissions,
  RoleCode,
  Roles,
} from '../common/auth.decorators';
import { PERMISSIONS } from '../common/permissions';
import { AuditService } from './audit.service';
import { AuditLogListDto, AuditLogQueryDto } from './dto/audit.dto';

@ApiTags('Audit')
@ApiBearerAuth()
@Controller('audit-logs')
export class AuditController {
  constructor(private readonly audit: AuditService) {}

  // Lecture SENSIBLE : l'accès est relu EN BASE (et non dans le seul token),
  // pour qu'un admin rétrogradé perde la vue du journal immédiatement — pas
  // 15 minutes plus tard, à l'expiration de son jeton.
  @Roles(RoleCode.ADMIN)
  @RequirePermissions(PERMISSIONS.AUDIT_READ)
  @RequireFreshAccess()
  @Get()
  @ApiOperation({
    summary: 'Journal des actions sensibles (admin uniquement)',
    description:
      'Prix, ajustements, validations, annulations, permissions, réceptions, ' +
      'transferts. Les ventes courantes n’y figurent pas — elles vivent dans le ' +
      'module Ventes. Lecture seule : aucune route ne modifie ni n’efface une ' +
      'entrée. Du plus récent au plus ancien.',
  })
  @ApiOkResponse({ type: AuditLogListDto })
  findAll(@Query() query: AuditLogQueryDto): Promise<AuditLogListDto> {
    return this.audit.findAll(query);
  }
}
