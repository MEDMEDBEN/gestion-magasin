import {
  Body,
  Controller,
  Get,
  HttpCode,
  HttpStatus,
  Ip,
  Param,
  Post,
  Query,
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
import {
  CloseTransferDto,
  CreateTransferDto,
  PrepareTransferDto,
  ReceiveTransferDto,
  TransferDto,
  TransferListDto,
  TransferListQueryDto,
} from './dto/transfer.dto';
import { TransfersService } from './transfers.service';

@ApiTags('Transferts')
@ApiBearerAuth()
@Controller('transfers')
export class TransfersController {
  constructor(private readonly transfers: TransfersService) {}

  @Roles(RoleCode.ADMIN, RoleCode.VENDEUR)
  @RequirePermissions(PERMISSIONS.TRANSFER_REQUEST)
  @Post()
  @ApiOperation({
    summary: 'Crée une demande magasin → dépôt',
    description:
      'Une demande est un vrai transfert suivi, jamais un simple message. Aucun ' +
      'mouvement de stock ici : la marchandise ne bouge qu’à l’expédition. ' +
      'Renvoi de la même `clientMutationId` → même demande, sans doublon.',
  })
  @ApiCreatedResponse({ type: TransferDto })
  @ApiConflictResponse({ type: ErrorResponseDto })
  request(
    @Body() dto: CreateTransferDto,
    @CurrentUser() user: AuthenticatedUser,
    @Ip() ip: string,
  ): Promise<TransferDto> {
    return this.transfers.request(dto, user, {
      userId: user.id,
      ipAddress: ip,
    });
  }

  // Lecture ouverte aux TROIS rôles de la matrice des transferts, sans
  // permission supplémentaire : chacun tient un bout du flux (le vendeur
  // demande et réceptionne, le magasinier prépare et expédie) et doit voir le
  // même tableau. Aucune permission existante n'est commune aux trois, et en
  // inventer une dépasserait `docs/permissions.md`.
  @Roles(RoleCode.ADMIN, RoleCode.VENDEUR, RoleCode.MAGASINIER)
  @Get()
  @ApiOperation({
    summary: 'Liste paginée des transferts (filtres statut, mes demandes)',
  })
  @ApiOkResponse({ type: TransferListDto })
  findAll(
    @Query() query: TransferListQueryDto,
    @CurrentUser() user: AuthenticatedUser,
  ): Promise<TransferListDto> {
    return this.transfers.findAll(query, user);
  }

  @Roles(RoleCode.ADMIN, RoleCode.VENDEUR, RoleCode.MAGASINIER)
  @Get(':id')
  @ApiOperation({ summary: 'Détail d’un transfert' })
  @ApiOkResponse({ type: TransferDto })
  findOne(@Param('id', CanonicalUuidPipe) id: string): Promise<TransferDto> {
    return this.transfers.findOne(id);
  }

  @Roles(RoleCode.ADMIN, RoleCode.MAGASINIER)
  @RequirePermissions(PERMISSIONS.TRANSFER_PREPARE)
  @Post(':id/accept')
  @HttpCode(HttpStatus.OK)
  @ApiOperation({
    summary: 'Accepte la demande (le dépôt s’en charge)',
    description: 'DEMANDEE → ACCEPTEE. Renvoyé, il rend l’état déjà atteint.',
  })
  @ApiOkResponse({ type: TransferDto })
  accept(
    @Param('id', CanonicalUuidPipe) id: string,
    @CurrentUser() user: AuthenticatedUser,
    @Ip() ip: string,
  ): Promise<TransferDto> {
    return this.transfers.accept(id, user, { userId: user.id, ipAddress: ip });
  }

  @Roles(RoleCode.ADMIN, RoleCode.MAGASINIER)
  @RequirePermissions(PERMISSIONS.TRANSFER_PREPARE)
  @Post(':id/prepare')
  @HttpCode(HttpStatus.OK)
  @ApiOperation({
    summary: 'Prépare la demande (préparation partielle autorisée)',
    description:
      'Enregistre les quantités réellement préparées, jamais plus que le ' +
      'demandé. `done: false` = préparation en cours (EN_PREPARATION), ' +
      '`done: true` = prête à expédier (PREPAREE). Aucun stock ne bouge encore.',
  })
  @ApiOkResponse({ type: TransferDto })
  @ApiConflictResponse({ type: ErrorResponseDto })
  prepare(
    @Param('id', CanonicalUuidPipe) id: string,
    @Body() dto: PrepareTransferDto,
    @CurrentUser() user: AuthenticatedUser,
    @Ip() ip: string,
  ): Promise<TransferDto> {
    return this.transfers.prepare(id, dto, user, {
      userId: user.id,
      ipAddress: ip,
    });
  }

  @Roles(RoleCode.ADMIN, RoleCode.MAGASINIER)
  @RequirePermissions(PERMISSIONS.TRANSFER_PREPARE)
  @Post(':id/ship')
  @HttpCode(HttpStatus.OK)
  @ApiOperation({
    summary: 'Expédie le transfert',
    description:
      'PREPAREE → EN_TRANSIT : sort le préparé du dépôt (TRANSFERT_SORTIE) et ' +
      'l’entre en transit (TRANSFERT_ENTREE). Le transfert ne s’annule plus après.',
  })
  @ApiOkResponse({ type: TransferDto })
  @ApiConflictResponse({ type: ErrorResponseDto })
  ship(
    @Param('id', CanonicalUuidPipe) id: string,
    @CurrentUser() user: AuthenticatedUser,
    @Ip() ip: string,
  ): Promise<TransferDto> {
    return this.transfers.ship(id, user, { userId: user.id, ipAddress: ip });
  }

  @Roles(RoleCode.ADMIN, RoleCode.VENDEUR)
  @RequirePermissions(PERMISSIONS.TRANSFER_RECEIVE)
  @Post(':id/receive')
  @HttpCode(HttpStatus.OK)
  @ApiOperation({
    summary: 'Réceptionne au magasin',
    description:
      'EN_TRANSIT → RECUE : vide le transit, entre au magasin ce qui est ' +
      'réellement arrivé, et RENVOIE l’écart au dépôt pour qu’il y soit ' +
      'constaté. Le produit n’est vendable qu’après cette étape.',
  })
  @ApiOkResponse({ type: TransferDto })
  @ApiConflictResponse({ type: ErrorResponseDto })
  receive(
    @Param('id', CanonicalUuidPipe) id: string,
    @Body() dto: ReceiveTransferDto,
    @CurrentUser() user: AuthenticatedUser,
    @Ip() ip: string,
  ): Promise<TransferDto> {
    return this.transfers.receive(id, dto, user, {
      userId: user.id,
      ipAddress: ip,
    });
  }

  @Roles(RoleCode.ADMIN, RoleCode.VENDEUR, RoleCode.MAGASINIER)
  @RequirePermissions(PERMISSIONS.TRANSFER_CANCEL)
  @Post(':id/cancel')
  @HttpCode(HttpStatus.OK)
  @ApiOperation({
    summary: 'Refuse (dépôt) ou annule (demandeur) un transfert',
    description:
      'Possible tant que rien n’est expédié. REFUSEE : administrateur ou ' +
      'magasinier. ANNULEE : administrateur, ou le vendeur auteur de la demande.',
  })
  @ApiOkResponse({ type: TransferDto })
  @ApiConflictResponse({ type: ErrorResponseDto })
  cancel(
    @Param('id', CanonicalUuidPipe) id: string,
    @Body() dto: CloseTransferDto,
    @CurrentUser() user: AuthenticatedUser,
    @Ip() ip: string,
  ): Promise<TransferDto> {
    return this.transfers.close(id, dto, user, {
      userId: user.id,
      ipAddress: ip,
    });
  }
}
