import {
  Body,
  Controller,
  Get,
  Ip,
  Param,
  Patch,
  Post,
  Query,
  UseGuards,
} from '@nestjs/common';
import {
  ApiBearerAuth,
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
import { FreshAccessGuard } from '../common/fresh-access.guard';
import { PERMISSIONS } from '../common/permissions';
import { CustomersService } from './customers.service';
import {
  CreateCustomerDto,
  CreateCustomerPaymentDto,
  CustomerDto,
  CustomerListDto,
  CustomerListQueryDto,
  CustomerPaymentDto,
  UpdateCustomerDto,
} from './dto/customer.dto';

const ALL_ROLES = [RoleCode.ADMIN, RoleCode.VENDEUR, RoleCode.MAGASINIER];

@ApiTags('Clients')
@ApiBearerAuth()
@Controller('customers')
export class CustomersController {
  constructor(private readonly customers: CustomersService) {}

  @Roles(...ALL_ROLES)
  @RequirePermissions(PERMISSIONS.CUSTOMER_READ)
  @Get()
  @ApiOperation({
    summary: 'Clients (recherche nom, téléphone, code) avec leur dette',
  })
  @ApiOkResponse({ type: CustomerListDto })
  findAll(@Query() query: CustomerListQueryDto): Promise<CustomerListDto> {
    return this.customers.findAll(query);
  }

  @Roles(...ALL_ROLES)
  @RequirePermissions(PERMISSIONS.CUSTOMER_READ)
  @Get(':id')
  @ApiOperation({ summary: 'Fiche client et dette recalculée' })
  @ApiOkResponse({ type: CustomerDto })
  findOne(@Param('id', CanonicalUuidPipe) id: string): Promise<CustomerDto> {
    return this.customers.findOne(id);
  }

  @Roles(RoleCode.ADMIN, RoleCode.VENDEUR)
  @RequirePermissions(PERMISSIONS.CUSTOMER_WRITE)
  // Tarif et plafond (conditions commerciales) : droits relus en base.
  @UseGuards(FreshAccessGuard)
  @Post()
  @ApiOperation({
    summary: 'Crée un client',
    description: 'Tarif et plafond de crédit : ADMIN seul (403 sinon).',
  })
  @ApiCreatedResponse({ type: CustomerDto })
  create(
    @Body() dto: CreateCustomerDto,
    @CurrentUser() user: AuthenticatedUser,
    @Ip() ip: string,
  ): Promise<CustomerDto> {
    return this.customers.create(dto, user, { userId: user.id, ipAddress: ip });
  }

  @Roles(RoleCode.ADMIN, RoleCode.VENDEUR)
  @RequirePermissions(PERMISSIONS.CUSTOMER_WRITE)
  @UseGuards(FreshAccessGuard)
  @Patch(':id')
  @ApiOperation({
    summary: 'Modifie un client (tarif et plafond : ADMIN seul)',
  })
  @ApiOkResponse({ type: CustomerDto })
  update(
    @Param('id', CanonicalUuidPipe) id: string,
    @Body() dto: UpdateCustomerDto,
    @CurrentUser() user: AuthenticatedUser,
    @Ip() ip: string,
  ): Promise<CustomerDto> {
    return this.customers.update(id, dto, user, {
      userId: user.id,
      ipAddress: ip,
    });
  }
}

@ApiTags('Paiements')
@ApiBearerAuth()
@Controller('payments')
export class CustomerPaymentsController {
  constructor(private readonly customers: CustomersService) {}

  @Roles(RoleCode.ADMIN, RoleCode.VENDEUR)
  @RequirePermissions(PERMISSIONS.CUSTOMER_PAYMENT_CREATE)
  @Post('customer')
  @ApiOperation({
    summary: 'Encaisse un règlement client (espèces, caisse ouverte)',
    description:
      'Jamais au-delà de la dette ; la dette reste TOUJOURS recalculée.',
  })
  @ApiCreatedResponse({ type: CustomerPaymentDto })
  pay(
    @Body() dto: CreateCustomerPaymentDto,
    @CurrentUser() user: AuthenticatedUser,
    @Ip() ip: string,
  ): Promise<CustomerPaymentDto> {
    return this.customers.pay(dto, user, { userId: user.id, ipAddress: ip });
  }
}
