import { HttpException, HttpStatus } from '@nestjs/common';
import { ErrorCode } from './error-codes';

/// Exception métier portant un `code` stable exploitable par le client.
/// Toute règle métier refusée DOIT lever ceci plutôt qu'une HttpException nue.
export class BusinessException extends HttpException {
  constructor(
    code: ErrorCode,
    message: string,
    status: HttpStatus = HttpStatus.BAD_REQUEST,
  ) {
    super({ statusCode: status, message, error: HttpStatus[status], code }, status);
  }
}
