import {
  Body,
  Controller,
  Get,
  HttpCode,
  HttpStatus,
  Ip,
  Param,
  Patch,
  Post,
  Query,
  StreamableFile,
} from '@nestjs/common';
import {
  ApiBearerAuth,
  ApiConflictResponse,
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
import { ErrorResponseDto } from '../common/dto/error-response.dto';
import { PERMISSIONS } from '../common/permissions';
import {
  ConvertQuoteDto,
  CreateQuoteDto,
  UpdateQuoteDto,
  QuoteDto,
  QuoteListDto,
  QuoteListQueryDto,
} from './dto/quote.dto';
import { SaleDto } from './dto/sale.dto';
import { QuotesService } from './quotes.service';

/// Devis (P1 n°21a, spec §8quater) : mêmes droits que la vente — ADMIN ou
/// VENDEUR avec `sale.create`. Un devis ne touche jamais le stock.
@ApiTags('Devis')
@ApiBearerAuth()
@Controller('quotes')
@Roles(RoleCode.ADMIN, RoleCode.VENDEUR)
@RequirePermissions(PERMISSIONS.SALE_CREATE)
export class QuotesController {
  constructor(private readonly quotes: QuotesService) {}

  @Post()
  @ApiOperation({
    summary:
      'Crée un devis (prix au tarif du client, aucun mouvement de stock)',
  })
  @ApiCreatedResponse({ type: QuoteDto })
  create(
    @Body() dto: CreateQuoteDto,
    @CurrentUser() user: AuthenticatedUser,
    @Ip() ip: string,
  ): Promise<QuoteDto> {
    return this.quotes.create(dto, user, { userId: user.id, ipAddress: ip });
  }

  @Get()
  @ApiOperation({ summary: 'Devis, du plus récent au plus ancien' })
  @ApiOkResponse({ type: QuoteListDto })
  findAll(@Query() query: QuoteListQueryDto): Promise<QuoteListDto> {
    return this.quotes.findAll(query);
  }

  @Get(':id')
  @ApiOkResponse({ type: QuoteDto })
  findOne(@Param('id', CanonicalUuidPipe) id: string): Promise<QuoteDto> {
    return this.quotes.findOne(id);
  }

  // Rendu synchrone : bridé comme le PDF d'une vente.
  @Throttle({ default: { ttl: 60_000, limit: 30 } })
  @Get(':id/pdf')
  @ApiOperation({ summary: 'PDF du devis (A4, même gabarit que la facture)' })
  @ApiProduces('application/pdf')
  @ApiOkResponse({ schema: { type: 'string', format: 'binary' } })
  async document(
    @Param('id', CanonicalUuidPipe) id: string,
  ): Promise<StreamableFile> {
    const { filename, pdf } = await this.quotes.renderDocument(id);
    return new StreamableFile(pdf, {
      type: 'application/pdf',
      disposition: `inline; filename="${filename}"`,
    });
  }

  @Patch(':id')
  @ApiOperation({
    summary: 'Modifie un devis BROUILLON (lignes remplacées et re-tarifées)',
  })
  @ApiOkResponse({ type: QuoteDto })
  @ApiConflictResponse({ type: ErrorResponseDto })
  update(
    @Param('id', CanonicalUuidPipe) id: string,
    @Body() dto: UpdateQuoteDto,
    @CurrentUser() user: AuthenticatedUser,
    @Ip() ip: string,
  ): Promise<QuoteDto> {
    return this.quotes.update(id, dto, user, {
      userId: user.id,
      ipAddress: ip,
    });
  }

  @Post(':id/send')
  @HttpCode(HttpStatus.OK)
  @ApiOperation({ summary: 'BROUILLON → ENVOYE' })
  @ApiOkResponse({ type: QuoteDto })
  @ApiConflictResponse({ type: ErrorResponseDto })
  send(
    @Param('id', CanonicalUuidPipe) id: string,
    @CurrentUser() user: AuthenticatedUser,
    @Ip() ip: string,
  ): Promise<QuoteDto> {
    return this.quotes.transition(id, 'send', {
      userId: user.id,
      ipAddress: ip,
    });
  }

  @Post(':id/accept')
  @HttpCode(HttpStatus.OK)
  @ApiOperation({ summary: 'BROUILLON ou ENVOYE → ACCEPTE (jamais expiré)' })
  @ApiOkResponse({ type: QuoteDto })
  @ApiConflictResponse({ type: ErrorResponseDto })
  accept(
    @Param('id', CanonicalUuidPipe) id: string,
    @CurrentUser() user: AuthenticatedUser,
    @Ip() ip: string,
  ): Promise<QuoteDto> {
    return this.quotes.transition(id, 'accept', {
      userId: user.id,
      ipAddress: ip,
    });
  }

  @Post(':id/refuse')
  @HttpCode(HttpStatus.OK)
  @ApiOperation({ summary: 'BROUILLON, ENVOYE ou ACCEPTE → REFUSE' })
  @ApiOkResponse({ type: QuoteDto })
  @ApiConflictResponse({ type: ErrorResponseDto })
  refuse(
    @Param('id', CanonicalUuidPipe) id: string,
    @CurrentUser() user: AuthenticatedUser,
    @Ip() ip: string,
  ): Promise<QuoteDto> {
    return this.quotes.transition(id, 'refuse', {
      userId: user.id,
      ipAddress: ip,
    });
  }

  @Post(':id/convert')
  @ApiOperation({
    summary: 'Devis ACCEPTÉ → vente (même cœur que POST /sales)',
    description:
      'Lignes, prix promis et client viennent du devis ; seul l’encaissement est ' +
      'transmis. Caisse, crédit, plafond, stock et plancher de prix sont vérifiés ' +
      'comme pour toute vente. Clé d’idempotence obligatoire. En ligne uniquement.',
  })
  @ApiCreatedResponse({ type: SaleDto })
  @ApiConflictResponse({ type: ErrorResponseDto })
  convert(
    @Param('id', CanonicalUuidPipe) id: string,
    @Body() dto: ConvertQuoteDto,
    @CurrentUser() user: AuthenticatedUser,
    @Ip() ip: string,
  ): Promise<SaleDto> {
    return this.quotes.convert(id, dto, user, {
      userId: user.id,
      ipAddress: ip,
    });
  }
}
