import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import {
  IsEnum,
  IsOptional,
  IsString,
  Matches,
  MaxLength,
} from 'class-validator';
import {
  PaginationMetaDto,
  PaginationQueryDto,
} from '../../common/dto/pagination.dto';
import { IsCanonicalUuid } from '../../common/validation';

export enum AuditActionDto {
  CREATE = 'CREATE',
  UPDATE = 'UPDATE',
  CANCEL = 'CANCEL',
  VALIDATE = 'VALIDATE',
  ADJUST = 'ADJUST',
  CLOSE = 'CLOSE',
}

export class AuditLogQueryDto extends PaginationQueryDto {
  @ApiPropertyOptional({
    example: 'Product',
    description: 'Type d’objet tracé (Product, Sale, Transfer, User…).',
  })
  @IsString()
  @MaxLength(40)
  @Matches(/^[A-Za-z]+$/, { message: 'entityType : lettres seulement' })
  @IsOptional()
  entityType?: string;

  @ApiPropertyOptional({ description: 'Historique d’UN objet précis.' })
  @IsCanonicalUuid()
  @IsOptional()
  entityId?: string;

  @ApiPropertyOptional({ description: 'Ce qu’a fait UN membre.' })
  @IsCanonicalUuid()
  @IsOptional()
  userId?: string;

  @ApiPropertyOptional({ enum: AuditActionDto })
  @IsEnum(AuditActionDto)
  @IsOptional()
  action?: AuditActionDto;

  @ApiPropertyOptional({
    example: '2026-09-01',
    description: 'À partir de ce jour (inclus, heure d’Alger), AAAA-MM-JJ.',
  })
  @IsString()
  @MaxLength(10)
  @IsOptional()
  from?: string;

  @ApiPropertyOptional({
    example: '2026-09-21',
    description: 'Jusqu’à ce jour (inclus, heure d’Alger), AAAA-MM-JJ.',
  })
  @IsString()
  @MaxLength(10)
  @IsOptional()
  to?: string;
}

export class AuditLogDto {
  @ApiProperty() id!: string;
  @ApiProperty({ nullable: true, description: 'null : action du système.' })
  userId!: string | null;
  @ApiProperty({
    nullable: true,
    description: 'Nom de l’auteur, pour la lecture.',
  })
  userName!: string | null;
  @ApiProperty({ enum: AuditActionDto }) action!: AuditActionDto;
  @ApiProperty({ example: 'Product' }) entityType!: string;
  @ApiProperty() entityId!: string;
  @ApiProperty({ nullable: true, type: Object })
  oldValue!: Record<string, unknown> | null;
  @ApiProperty({ nullable: true, type: Object })
  newValue!: Record<string, unknown> | null;
  @ApiProperty({ nullable: true }) ipAddress!: string | null;
  @ApiProperty() createdAt!: Date;
}

export class AuditLogListDto {
  @ApiProperty({ type: [AuditLogDto] }) data!: AuditLogDto[];
  @ApiProperty({ type: PaginationMetaDto }) meta!: PaginationMetaDto;
}
