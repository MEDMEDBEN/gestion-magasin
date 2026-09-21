import { Controller, Get, Query } from '@nestjs/common';
import {
  ApiBearerAuth,
  ApiOkResponse,
  ApiOperation,
  ApiProperty,
  ApiTags,
} from '@nestjs/swagger';
import { RequirePermissions, RoleCode, Roles } from '../common/auth.decorators';
import { PaginationQueryDto } from '../common/dto/pagination.dto';
import { notImplemented } from '../common/not-implemented';
import { PERMISSIONS } from '../common/permissions';

export class AuditLogDto {
  @ApiProperty() id!: string;
  @ApiProperty({ nullable: true }) userId!: string | null;
  @ApiProperty({
    example: 'UPDATE',
    description: 'CREATE | UPDATE | CANCEL | VALIDATE | ADJUST',
  })
  action!: string;
  @ApiProperty() entityType!: string;
  @ApiProperty() entityId!: string;
  @ApiProperty({ nullable: true }) oldValue!: Record<string, unknown> | null;
  @ApiProperty({ nullable: true }) newValue!: Record<string, unknown> | null;
  @ApiProperty() createdAt!: Date;
}

/// CONTRAT FIGÉ — implémentation avec la feature P0 n°11 « Historique / audit ».
/// (Sorti de `planning/` : il y partageait le fichier du planning, P0 n°10.)
@ApiTags('Audit')
@ApiBearerAuth()
@Controller('audit-logs')
export class AuditController {
  @Roles(RoleCode.ADMIN)
  @RequirePermissions(PERMISSIONS.AUDIT_READ)
  @Get()
  @ApiOperation({
    summary: 'Journal des actions sensibles (admin uniquement)',
    description:
      'Prix, ajustements, validations, annulations, permissions. ' +
      'Les ventes courantes n’y figurent pas — elles vivent dans le module Ventes.',
  })
  @ApiOkResponse({ type: [AuditLogDto] })
  findAll(@Query() _query: PaginationQueryDto): Promise<AuditLogDto[]> {
    return notImplemented('Historique / audit');
  }
}
