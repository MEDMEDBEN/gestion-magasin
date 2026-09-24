import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import { Transform } from 'class-transformer';
import {
  IsEnum,
  IsOptional,
  IsString,
  MaxLength,
  MinLength,
} from 'class-validator';
import {
  PaginationMetaDto,
  PaginationQueryDto,
} from '../../common/dto/pagination.dto';
import {
  ClientGeneratedId,
  IsCanonicalUuid,
  IsOptionalNotNull,
} from '../../common/validation';
import {
  Priority,
  ProblemCategory,
  ProblemStatus,
} from '../../generated/prisma/enums';

const trim = ({ value }: { value: unknown }) =>
  typeof value === 'string' ? value.trim() : value;

export class CreateProblemDto {
  @ApiPropertyOptional({ description: 'UUID généré par le client.' })
  @ClientGeneratedId()
  id?: string;

  @ApiProperty({ example: 'Stock faux sur le câble 2,5 mm²' })
  @Transform(trim)
  @IsString()
  @MinLength(3)
  @MaxLength(120)
  title!: string;

  @ApiProperty({ enum: ProblemCategory })
  @IsEnum(ProblemCategory)
  category!: ProblemCategory;

  @ApiProperty({
    description: 'Ce qui a été constaté, assez précis pour être vérifié.',
  })
  @Transform(trim)
  @IsString()
  @MinLength(5)
  @MaxLength(2000)
  description!: string;

  @ApiPropertyOptional({ enum: Priority, default: 'NORMALE' })
  @IsEnum(Priority)
  @IsOptional()
  priority?: Priority;

  @ApiPropertyOptional({ description: 'Produit concerné, s’il y en a un.' })
  @IsOptionalNotNull()
  @IsCanonicalUuid()
  productId?: string;

  @ApiPropertyOptional({ description: 'Emplacement concerné, s’il y en a un.' })
  @IsOptionalNotNull()
  @IsCanonicalUuid()
  locationId?: string;
}

export class AssignProblemDto {
  @ApiProperty({ description: 'Membre qui prend le signalement en charge.' })
  @IsCanonicalUuid()
  assignedToId!: string;
}

export class ResolveProblemDto {
  @ApiProperty({
    description:
      'Ce qui a été fait. OBLIGATOIRE : un problème clos sans explication ' +
      'ne sert à personne six mois plus tard.',
  })
  @Transform(trim)
  @IsString()
  @MinLength(5)
  @MaxLength(2000)
  resolution!: string;
}

export class ProblemListQueryDto extends PaginationQueryDto {
  @ApiPropertyOptional({ enum: ProblemStatus })
  @IsEnum(ProblemStatus)
  @IsOptional()
  status?: ProblemStatus;

  @ApiPropertyOptional({ enum: ProblemCategory })
  @IsEnum(ProblemCategory)
  @IsOptional()
  category?: ProblemCategory;

  @ApiPropertyOptional({ description: 'Ne rendre que ceux que J’AI signalés.' })
  @IsOptional()
  @IsString()
  mine?: string;
}

export class ProblemDto {
  @ApiProperty() id!: string;
  @ApiProperty() title!: string;
  @ApiProperty({ enum: ProblemCategory }) category!: string;
  @ApiProperty() description!: string;
  @ApiProperty({ enum: Priority }) priority!: string;
  @ApiProperty({ enum: ProblemStatus }) status!: string;
  @ApiProperty({
    description: 'Une photo est jointe (récupérable sur /problems/:id/photo).',
  })
  hasPhoto!: boolean;
  @ApiProperty({ nullable: true }) productId!: string | null;
  @ApiProperty({ nullable: true }) productName!: string | null;
  @ApiProperty({ nullable: true }) locationId!: string | null;
  @ApiProperty({ nullable: true }) locationName!: string | null;
  @ApiProperty() reportedById!: string;
  @ApiProperty() reportedByName!: string;
  @ApiProperty({ nullable: true }) assignedToId!: string | null;
  @ApiProperty({ nullable: true }) assignedToName!: string | null;
  @ApiProperty({ nullable: true }) resolution!: string | null;
  @ApiProperty({ nullable: true }) resolvedAt!: string | null;
  @ApiProperty({ nullable: true }) closedAt!: string | null;
  @ApiProperty() createdAt!: string;
}

export class ProblemListDto {
  @ApiProperty({ type: [ProblemDto] }) data!: ProblemDto[];
  @ApiProperty({ type: PaginationMetaDto }) meta!: PaginationMetaDto;
}
