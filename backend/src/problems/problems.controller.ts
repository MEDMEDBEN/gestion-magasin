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
  Res,
  UploadedFile,
  UseInterceptors,
} from '@nestjs/common';
import { FileInterceptor } from '@nestjs/platform-express';
import { Throttle } from '@nestjs/throttler';
import {
  ApiBearerAuth,
  ApiConsumes,
  ApiCreatedResponse,
  ApiNotFoundResponse,
  ApiOkResponse,
  ApiOperation,
  ApiProduces,
  ApiTags,
} from '@nestjs/swagger';
import { Response } from 'express';
import { ActorContext } from '../audit/audit-writer';

import {
  AuthenticatedUser,
  CurrentUser,
  RequireFreshAccess,
  RoleCode,
  Roles,
} from '../common/auth.decorators';
import { CanonicalUuidPipe } from '../common/canonical-uuid.pipe';
import { IMAGE_UPLOAD_LIMITS } from '../common/uploads';
import {
  AssignProblemDto,
  CreateProblemDto,
  ProblemDto,
  ProblemListDto,
  ProblemListQueryDto,
  ResolveProblemDto,
} from './dto/problem.dto';
import { ProblemsService } from './problems.service';

/// `@HttpCode(OK)` sur les transitions : un POST rend 201 Created par defaut,
/// or aucune de ces routes ne cree de ressource — elles modifient celle qui
/// existe. Sans ca, le contrat OpenAPI (`@ApiOkResponse`) mentait.
const ALL_ROLES = [RoleCode.ADMIN, RoleCode.VENDEUR, RoleCode.MAGASINIER];

/// Qui agit, et depuis où — même forme que les autres contrôleurs.
const actorOf = (user: AuthenticatedUser, ip?: string): ActorContext => ({
  userId: user.id,
  ipAddress: ip ?? null,
});

/// Signalement de problème (spec §26).
///
/// SIGNALER est ouvert aux trois rôles, sans permission : celui qui voit le
/// problème est rarement celui qui a le droit de le corriger, et un signalement
/// qu'on ne peut pas déposer ne remonte jamais.
///
/// Les signalements sont visibles de toute l'équipe — c'est de l'information
/// opérationnelle, ni argent ni donnée personnelle. Ce qui est gardé, ce sont
/// les DÉCISIONS : attribuer et fermer sont réservés à l'ADMIN.
@ApiTags('Signalements')
@ApiBearerAuth()
@Controller('problems')
export class ProblemsController {
  constructor(private readonly problems: ProblemsService) {}

  @Roles(...ALL_ROLES)
  @RequireFreshAccess()
  @Get()
  @ApiOperation({
    summary: 'Les signalements de l’équipe',
    description:
      'Filtres : `status`, `category`, `mine=true` (ceux que j’ai signalés).',
  })
  @ApiOkResponse({ type: ProblemListDto })
  findAll(
    @CurrentUser() user: AuthenticatedUser,
    @Query() query: ProblemListQueryDto,
  ): Promise<ProblemListDto> {
    return this.problems.findAll(user, query);
  }

  @Roles(...ALL_ROLES)
  @RequireFreshAccess()
  @Get(':id')
  @ApiOperation({ summary: 'Un signalement' })
  @ApiOkResponse({ type: ProblemDto })
  findOne(@Param('id', CanonicalUuidPipe) id: string): Promise<ProblemDto> {
    return this.problems.findOne(id);
  }

  // Débit bridé : chaque signalement notifie TOUS les admins. Sans borne, un
  // compte peut noyer leur boîte et enterrer les vrais signalements.
  @Throttle({ default: { ttl: 60_000, limit: 20 } })
  @Roles(...ALL_ROLES)
  @Post()
  @ApiOperation({
    summary: 'Signaler un problème',
    description:
      'Ne corrige RIEN par lui-même : un stock faux se répare par un ' +
      'inventaire ou un ajustement tracé. Ceci sert à ce que ce soit su.',
  })
  @ApiCreatedResponse({ type: ProblemDto })
  create(
    @Body() dto: CreateProblemDto,
    @CurrentUser() user: AuthenticatedUser,
    @Ip() ip: string,
  ): Promise<ProblemDto> {
    return this.problems.create(dto, user, actorOf(user, ip));
  }

  @Roles(RoleCode.ADMIN)
  @HttpCode(HttpStatus.OK)
  @Post(':id/assign')
  @ApiOperation({ summary: 'Confier le signalement à un membre (admin)' })
  @ApiOkResponse({ type: ProblemDto })
  assign(
    @Param('id', CanonicalUuidPipe) id: string,
    @Body() dto: AssignProblemDto,
    @CurrentUser() user: AuthenticatedUser,
    @Ip() ip: string,
  ): Promise<ProblemDto> {
    return this.problems.assign(id, dto, user, actorOf(user, ip));
  }

  @Roles(...ALL_ROLES)
  @HttpCode(HttpStatus.OK)
  @Post(':id/start')
  @ApiOperation({
    summary: 'Je m’en occupe',
    description:
      'Le membre désigné, l’admin, ou n’importe qui tant que personne n’est ' +
      'désigné — le prendre se l’attribue.',
  })
  @ApiOkResponse({ type: ProblemDto })
  start(
    @Param('id', CanonicalUuidPipe) id: string,
    @CurrentUser() user: AuthenticatedUser,
    @Ip() ip: string,
  ): Promise<ProblemDto> {
    return this.problems.start(id, user, actorOf(user, ip));
  }

  @Roles(...ALL_ROLES)
  @HttpCode(HttpStatus.OK)
  @Post(':id/resolve')
  @ApiOperation({
    summary: 'Marquer résolu, en disant ce qui a été fait',
    description: 'L’explication est OBLIGATOIRE (spec §26).',
  })
  @ApiOkResponse({ type: ProblemDto })
  resolve(
    @Param('id', CanonicalUuidPipe) id: string,
    @Body() dto: ResolveProblemDto,
    @CurrentUser() user: AuthenticatedUser,
    @Ip() ip: string,
  ): Promise<ProblemDto> {
    return this.problems.resolve(id, dto, user, actorOf(user, ip));
  }

  @Roles(RoleCode.ADMIN)
  @HttpCode(HttpStatus.OK)
  @Post(':id/close')
  @ApiOperation({
    summary: 'Fermer (admin) — seulement ce qui est RÉSOLU',
    description: 'L’admin constate que la correction tient.',
  })
  @ApiOkResponse({ type: ProblemDto })
  close(
    @Param('id', CanonicalUuidPipe) id: string,
    @CurrentUser() user: AuthenticatedUser,
    @Ip() ip: string,
  ): Promise<ProblemDto> {
    return this.problems.close(id, user, actorOf(user, ip));
  }

  @Throttle({ default: { ttl: 60_000, limit: 20 } })
  @Roles(...ALL_ROLES)
  @HttpCode(HttpStatus.OK)
  @Post(':id/photo')
  // BORNES obligatoires : le corps JSON est limité par Express, pas le
  // multipart. Sans elles, un fichier de plusieurs centaines de Mo est chargé
  // ENTIÈREMENT en mémoire avant le moindre contrôle (audit sécurité).
  @UseInterceptors(FileInterceptor('file', { limits: IMAGE_UPLOAD_LIMITS }))
  @ApiConsumes('multipart/form-data')
  @ApiOperation({
    summary: 'Joindre une photo (auteur du signalement ou admin)',
    description: '« Le produit est abîmé » se conteste, une photo non.',
  })
  @ApiOkResponse({ type: ProblemDto })
  photo(
    @Param('id', CanonicalUuidPipe) id: string,
    @UploadedFile() file: Express.Multer.File | undefined,
    @CurrentUser() user: AuthenticatedUser,
    @Ip() ip: string,
  ): Promise<ProblemDto> {
    return this.problems.attachPhoto(id, file, user, actorOf(user, ip));
  }

  @Roles(...ALL_ROLES)
  @RequireFreshAccess()
  @Get(':id/photo')
  @ApiOperation({
    summary: 'Photo du signalement (authentifiée)',
    description: 'Le stockage est privé : elle ne sort que par cette route.',
  })
  @ApiProduces('image/jpeg', 'image/png', 'image/webp')
  @ApiNotFoundResponse({ description: 'Aucune photo sur ce signalement' })
  async openPhoto(
    @Param('id', CanonicalUuidPipe) id: string,
    @Res() res: Response,
  ): Promise<void> {
    const { stream, contentType } = await this.problems.openPhoto(id);
    res.setHeader('Content-Type', contentType);
    res.setHeader('Cache-Control', 'private, max-age=86400');
    res.setHeader('X-Content-Type-Options', 'nosniff');
    // `pipe` ne transmet PAS l'erreur de la source : un `error` sur le flux de
    // lecture (fichier disparu entre-temps, EIO, volume démonté) sans écouteur
    // devient une `uncaughtException` et tue le processus — aucun filtre Nest
    // ne l'attrape. On coupe la réponse, la requête seule échoue.
    stream.on('error', () => res.destroy());
    stream.pipe(res);
  }
}
