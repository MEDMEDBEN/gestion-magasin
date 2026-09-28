import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import { Transform } from 'class-transformer';
import {
  IsIn,
  IsOptional,
  IsString,
  Matches,
  MaxLength,
  MinLength,
} from 'class-validator';
import { DAY_MESSAGE, DAY_PATTERN } from './day-period.dto';
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
  @ApiPropertyOptional({
    nullable: true,
    description:
      'Clients : avoir d’un retour déduit de la dette (ni espèces, ni contre-passable).',
  })
  saleReturnId?: string | null;
}

export class PaymentHistoryDto {
  @ApiProperty({ type: [PaymentHistoryItemDto] })
  data!: PaymentHistoryItemDto[];
  @ApiProperty({ type: PaginationMetaDto }) meta!: PaginationMetaDto;
}

const trim = ({ value }: { value: unknown }) =>
  typeof value === 'string' ? value.trim() : value;

/// Chèque joint à un règlement client ou à un paiement fournisseur (P1 bis
/// n°21n, décisions MEDMEDBEN 2026-09-28) : il n'entre ni ne sort d'AUCUNE
/// caisse ; il reste « en portefeuille » jusqu'à ce que l'ADMIN le déclare
/// encaissé ou rejeté.
export class ChequeInputDto {
  @ApiProperty({ example: '0012345' })
  @Transform(trim)
  @IsString()
  @MinLength(1)
  @MaxLength(40)
  number!: string;

  @ApiProperty({ example: 'BNA Alger-Centre' })
  @Transform(trim)
  @IsString()
  @MinLength(1)
  @MaxLength(80)
  bank!: string;

  @ApiPropertyOptional({
    example: '2026-10-15',
    description:
      'Date à partir de laquelle le chèque peut être remis en banque.',
  })
  @Matches(DAY_PATTERN, { message: `dueDate : ${DAY_MESSAGE}` })
  @IsOptional()
  dueDate?: string;
}

export const CHEQUE_STATUSES = [
  'EN_PORTEFEUILLE',
  'ENCAISSE',
  'REJETE',
] as const;

/// Décision de l'ADMIN sur un chèque en portefeuille. REJETE contre-passe le
/// règlement (la dette revient) : mutation d'argent, clé d'idempotence.
export class ChequeStatusDto {
  @ClientMutationId()
  clientMutationId!: string;

  @ApiProperty({ enum: ['ENCAISSE', 'REJETE'] })
  @IsIn(['ENCAISSE', 'REJETE'])
  status!: 'ENCAISSE' | 'REJETE';

  @ApiPropertyOptional({ example: 'Provision insuffisante' })
  @Transform(trim)
  @IsString()
  @MaxLength(300)
  @IsOptional()
  reason?: string;
}

export class ChequeListQueryDto {
  @ApiPropertyOptional({ enum: CHEQUE_STATUSES })
  @IsIn(CHEQUE_STATUSES)
  @IsOptional()
  status?: (typeof CHEQUE_STATUSES)[number];
}

/// Un chèque du portefeuille : reçu d'un client ou émis à un fournisseur.
export class ChequeDto {
  @ApiProperty({ description: 'Id du règlement / paiement.' }) id!: string;
  @ApiProperty({ enum: ['CLIENT', 'FOURNISSEUR'] })
  kind!: 'CLIENT' | 'FOURNISSEUR';
  @ApiProperty() partyId!: string;
  @ApiProperty() partyName!: string;
  @ApiProperty({ description: 'Centimes.' }) amount!: number;
  @ApiProperty() number!: string;
  @ApiProperty() bank!: string;
  @ApiProperty({ nullable: true, example: '2026-10-15' })
  dueDate!: string | null;
  @ApiProperty({ enum: CHEQUE_STATUSES })
  status!: (typeof CHEQUE_STATUSES)[number];
  @ApiProperty() paidAt!: Date;
  @ApiProperty({ nullable: true }) statusAt!: Date | null;
}
