import {
  applyDecorators,
  Controller,
  Get,
  HttpCode,
  HttpStatus,
  Ip,
  Post,
  Query,
  UploadedFile,
  UseInterceptors,
} from '@nestjs/common';
import { FileInterceptor } from '@nestjs/platform-express';
import {
  ApiBearerAuth,
  ApiBody,
  ApiConsumes,
  ApiOkResponse,
  ApiOperation,
  ApiProduces,
  ApiPropertyOptional,
  ApiTags,
} from '@nestjs/swagger';
import { Throttle } from '@nestjs/throttler';
import { Transform } from 'class-transformer';
import { IsBoolean, IsOptional } from 'class-validator';
import {
  AuthenticatedUser,
  CurrentUser,
  RequirePermissions,
  RoleCode,
  Roles,
} from '../common/auth.decorators';
import { BusinessException } from '../common/business.exception';
import { ErrorCode } from '../common/error-codes';
import {
  EXPORT_TYPES,
  ExportFormatQueryDto,
  exportResponse,
} from '../common/export/export';
import { PERMISSIONS } from '../common/permissions';
import { IMPORT_UPLOAD_LIMITS } from '../common/uploads';
import { booleanQuery } from '../common/validation';
import { ImportReportDto } from './dto/import.dto';
import { ImportKind, ImportsService } from './imports.service';

class ImportQueryDto {
  @ApiPropertyOptional({
    default: true,
    description:
      'Vrai (défaut) : vérifie tout le fichier et liste les erreurs, SANS ' +
      'rien écrire. Faux : crée tout d’un bloc, ou rien.',
  })
  @Transform(booleanQuery)
  @IsBoolean()
  @IsOptional()
  dryRun = true;
}

/// Envoi d'un fichier d'import, borné AVANT lecture (`common/uploads.ts`).
const Upload = () =>
  applyDecorators(
    UseInterceptors(FileInterceptor('file', { limits: IMPORT_UPLOAD_LIMITS })),
    ApiConsumes('multipart/form-data'),
    ApiBody({
      schema: {
        type: 'object',
        properties: { file: { type: 'string', format: 'binary' } },
      },
    }),
    ApiOkResponse({ type: ImportReportDto }),
    HttpCode(HttpStatus.OK),
    // Une vérification relit tout le fichier : bridée comme un document.
    Throttle({ default: { ttl: 60_000, limit: 10 } }),
  );

const Template = () =>
  applyDecorators(
    ApiOperation({
      summary: 'Modèle à remplir (en-têtes + une ligne d’exemple)',
    }),
    ApiProduces(...EXPORT_TYPES),
    ApiOkResponse({ schema: { type: 'string', format: 'binary' } }),
  );

/// Import Excel/CSV (spec §8quinquies, P1 n°21c) : la mise en place du
/// magasin — catalogue, clients, fournisseurs. ADMIN seul, avec le droit
/// d'ÉCRITURE de ce qu'il importe : c'est de la saisie en masse.
@ApiTags('Import')
@ApiBearerAuth()
@Controller('imports')
@Roles(RoleCode.ADMIN)
export class ImportsController {
  constructor(private readonly imports: ImportsService) {}

  /// Produits : fiche, prix par tarif et stock initial (par le journal).
  @RequirePermissions(PERMISSIONS.PRODUCT_WRITE, PERMISSIONS.PRICE_MANAGE)
  @Post('products')
  @Upload()
  @ApiOperation({ summary: 'Importe des produits (Excel ou CSV)' })
  products(
    @UploadedFile() file: Express.Multer.File | undefined,
    @Query() query: ImportQueryDto,
    @CurrentUser() user: AuthenticatedUser,
    @Ip() ip: string,
  ): Promise<ImportReportDto> {
    return this.run('products', file, query, user, ip);
  }

  @RequirePermissions(PERMISSIONS.CUSTOMER_WRITE)
  @Post('customers')
  @Upload()
  @ApiOperation({ summary: 'Importe des clients (Excel ou CSV)' })
  customers(
    @UploadedFile() file: Express.Multer.File | undefined,
    @Query() query: ImportQueryDto,
    @CurrentUser() user: AuthenticatedUser,
    @Ip() ip: string,
  ): Promise<ImportReportDto> {
    return this.run('customers', file, query, user, ip);
  }

  /// Fournisseurs, avec leur reprise de dette : de l'argent — création
  /// seulement, un nom déjà connu est refusé, donc un renvoi ne double rien.
  @RequirePermissions(PERMISSIONS.SUPPLIER_WRITE)
  @Post('suppliers')
  @Upload()
  @ApiOperation({ summary: 'Importe des fournisseurs (Excel ou CSV)' })
  suppliers(
    @UploadedFile() file: Express.Multer.File | undefined,
    @Query() query: ImportQueryDto,
    @CurrentUser() user: AuthenticatedUser,
    @Ip() ip: string,
  ): Promise<ImportReportDto> {
    return this.run('suppliers', file, query, user, ip);
  }

  // ── Modèles à remplir : mêmes gardes que l'import correspondant ─────────

  @RequirePermissions(PERMISSIONS.PRODUCT_WRITE, PERMISSIONS.PRICE_MANAGE)
  @Get('products/template')
  @Template()
  async productsTemplate(@Query() query: ExportFormatQueryDto) {
    return exportResponse(
      await this.imports.template('products', query.format),
    );
  }

  @RequirePermissions(PERMISSIONS.CUSTOMER_WRITE)
  @Get('customers/template')
  @Template()
  async customersTemplate(@Query() query: ExportFormatQueryDto) {
    return exportResponse(
      await this.imports.template('customers', query.format),
    );
  }

  @RequirePermissions(PERMISSIONS.SUPPLIER_WRITE)
  @Get('suppliers/template')
  @Template()
  async suppliersTemplate(@Query() query: ExportFormatQueryDto) {
    return exportResponse(
      await this.imports.template('suppliers', query.format),
    );
  }

  private run(
    kind: ImportKind,
    file: Express.Multer.File | undefined,
    query: ImportQueryDto,
    user: AuthenticatedUser,
    ip: string,
  ): Promise<ImportReportDto> {
    if (!file?.buffer?.length) {
      throw new BusinessException(
        ErrorCode.VALIDATION_FAILED,
        'Fichier manquant : envoyez un classeur Excel ou un CSV (champ « file »)',
        HttpStatus.BAD_REQUEST,
      );
    }
    return this.imports.importFile(kind, file.buffer, query.dryRun, {
      userId: user.id,
      ipAddress: ip,
    });
  }
}
