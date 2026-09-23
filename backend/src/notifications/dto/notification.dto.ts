import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import { IsBoolean, IsOptional } from 'class-validator';
import {
  PaginationMetaDto,
  PaginationQueryDto,
} from '../../common/dto/pagination.dto';
import { booleanQuery } from '../../common/validation';
import {
  NotificationType,
  OperationType,
  Priority,
} from '../../generated/prisma/enums';
import { Transform } from 'class-transformer';

export class NotificationListQueryDto extends PaginationQueryDto {
  @ApiPropertyOptional({
    description: 'Ne rendre que les non lues (badge, écran « à traiter »).',
  })
  @Transform(booleanQuery)
  @IsBoolean()
  @IsOptional()
  unreadOnly?: boolean;
}

export class NotificationDto {
  @ApiProperty() id!: string;
  // Enums PORTÉES par le contrat (CONVENTIONS.md) : les mêmes valeurs en base,
  // dans l'API et dans l'app — un `string` d'exemple laissait la liste dériver.
  @ApiProperty({ enum: NotificationType, example: 'NOUVELLE_DEMANDE_DEPOT' })
  type!: string;
  @ApiProperty({ enum: Priority, example: 'NORMALE' }) priority!: string;
  @ApiProperty() title!: string;
  @ApiProperty({ nullable: true }) body!: string | null;
  @ApiProperty() isRead!: boolean;
  @ApiProperty({ nullable: true }) readAt!: string | null;
  @ApiProperty({
    enum: OperationType,
    nullable: true,
    description: 'Opération visée — c’est le lien qui rend l’alerte utile.',
  })
  operationType!: string | null;
  @ApiProperty({ nullable: true }) operationId!: string | null;
  @ApiProperty() createdAt!: string;
}

export class NotificationListDto {
  @ApiProperty({ type: [NotificationDto] }) data!: NotificationDto[];
  @ApiProperty({ type: PaginationMetaDto }) meta!: PaginationMetaDto;
  @ApiProperty({
    description: 'Non lues au TOTAL, indépendamment du filtre et de la page.',
  })
  unread!: number;
}

export class UnreadCountDto {
  @ApiProperty() unread!: number;
}
