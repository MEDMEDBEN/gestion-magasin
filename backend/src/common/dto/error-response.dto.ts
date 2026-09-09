import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import { ErrorCode } from '../error-codes';

/// Forme unique de toute réponse en erreur, documentée dans OpenAPI.
export class ErrorResponseDto {
  @ApiProperty({ example: 400 }) statusCode!: number;
  @ApiProperty({ example: 'Stock insuffisant pour le produit LED 12W' })
  message!: string | string[];
  @ApiProperty({ example: 'Bad Request' }) error!: string;
  @ApiPropertyOptional({
    enum: ErrorCode,
    description: 'Code métier stable — le client se base sur CE champ.',
  })
  code?: ErrorCode;
}
