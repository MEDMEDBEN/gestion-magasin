import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import { Type } from 'class-transformer';
import {
  IsInt,
  IsOptional,
  IsString,
  Max,
  MaxLength,
  Min,
} from 'class-validator';
import { LocationDto } from '../../locations/dto/location.dto';
import { CategoryDto, ProductDto, TaxRateDto } from './product.dto';

export class CatalogChangesQueryDto {
  @ApiPropertyOptional({
    description: 'Curseur opaque renvoyé par l’appel précédent. Absent = tout.',
  })
  @IsString()
  @MaxLength(1000)
  @IsOptional()
  cursor?: string;

  @ApiPropertyOptional({
    default: 500,
    maximum: 1000,
    description: 'Lignes max PAR TYPE',
  })
  @Type(() => Number)
  @IsInt()
  @Min(1)
  @Max(1000)
  @IsOptional()
  limit = 500;
}

export class CatalogChangesDto {
  @ApiProperty({ type: [ProductDto] }) products!: ProductDto[];
  @ApiProperty({ type: [CategoryDto] }) categories!: CategoryDto[];
  @ApiProperty({ type: [LocationDto] }) locations!: LocationDto[];
  @ApiProperty({ type: [TaxRateDto] }) taxRates!: TaxRateDto[];
  @ApiProperty({ description: 'À conserver et renvoyer au prochain appel' })
  cursor!: string;
  @ApiProperty({
    description: 'Vrai : rappeler immédiatement avec le nouveau curseur',
  })
  hasMore!: boolean;
}
