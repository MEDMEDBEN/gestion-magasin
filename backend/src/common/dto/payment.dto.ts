import { ApiProperty } from '@nestjs/swagger';
import { Transform } from 'class-transformer';
import { IsString, MaxLength, MinLength } from 'class-validator';
import { ClientMutationId } from '../idempotency';
import { PaginationMetaDto } from './pagination.dto';

/// Contre-passation d'un règlement client ou d'un paiement fournisseur
/// (décision MEDMEDBEN 2026-09-16) : une écriture OPPOSÉE est ajoutée, le
/// paiement d'origine n'est jamais supprimé ni modifié (règle 7).
export class ReversePaymentDto {
  @ClientMutationId()
  clientMutationId!: string;

  @ApiProperty({
    example: 'Montant saisi par erreur (3 000 au lieu de 300)',
    description: 'Motif obligatoire, conservé sur l’écriture et à l’audit.',
  })
  @Transform(({ value }: { value: unknown }) =>
    typeof value === 'string' ? value.trim() : value,
  )
  @IsString()
  @MinLength(3)
  @MaxLength(500)
  reason!: string;
}

/// Ligne d'historique des paiements (clients ou fournisseurs).
export class PaymentHistoryItemDto {
  @ApiProperty() id!: string;
  @ApiProperty({
    description: 'Centimes ; NÉGATIF pour une contre-passation.',
  })
  amount!: number;
  @ApiProperty() method!: string;
  @ApiProperty({ description: 'Espèces passées par une caisse.' })
  fromCash!: boolean;
  @ApiProperty() paidAt!: Date;
  @ApiProperty() userId!: string;
  @ApiProperty({ nullable: true }) saleId!: string | null;
  @ApiProperty({ nullable: true }) note!: string | null;
  @ApiProperty({
    nullable: true,
    description: 'Ce paiement contre-passe le paiement indiqué.',
  })
  reversesPaymentId!: string | null;
  @ApiProperty({
    nullable: true,
    description: 'Contre-passation qui annule ce paiement, s’il y en a une.',
  })
  reversedById!: string | null;
}

export class PaymentHistoryDto {
  @ApiProperty({ type: [PaymentHistoryItemDto] })
  data!: PaymentHistoryItemDto[];
  @ApiProperty({ type: PaginationMetaDto }) meta!: PaginationMetaDto;
}
