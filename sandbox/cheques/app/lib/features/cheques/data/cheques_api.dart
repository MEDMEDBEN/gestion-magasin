import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:freezed_annotation/freezed_annotation.dart';

import '../../../core/error/api_exception.dart';
import '../../../core/providers.dart';

part 'cheques_api.freezed.dart';
part 'cheques_api.g.dart';

/// Statut d'un chèque (P1 bis n°21n) : remis / émis, passé en banque, ou
/// refusé (le règlement est alors contre-passé, la dette revient).
enum ChequeStatus {
  @JsonValue('EN_PORTEFEUILLE')
  inWallet('En portefeuille'),
  @JsonValue('ENCAISSE')
  cashed('Encaissé'),
  @JsonValue('REJETE')
  rejected('Rejeté');

  const ChequeStatus(this.label);
  final String label;

  String get wire => switch (this) {
    ChequeStatus.inWallet => 'EN_PORTEFEUILLE',
    ChequeStatus.cashed => 'ENCAISSE',
    ChequeStatus.rejected => 'REJETE',
  };
}

/// Chèque reçu d'un client (`CLIENT`) ou émis à un fournisseur
/// (`FOURNISSEUR`). Montant en centimes (règle 4).
@freezed
abstract class Cheque with _$Cheque {
  const factory Cheque({
    required String id,
    required String kind,
    required String partyId,
    required String partyName,
    required int amount,
    required String number,
    required String bank,
    String? dueDate,
    required ChequeStatus status,
    required DateTime paidAt,
    DateTime? statusAt,
  }) = _Cheque;

  const Cheque._();

  bool get isCustomer => kind == 'CLIENT';

  factory Cheque.fromJson(Map<String, dynamic> json) => _$ChequeFromJson(json);
}

/// Portefeuille (ADMIN) et décisions. EN LIGNE uniquement : une décision
/// contre-passe un règlement, le serveur seul en juge.
class ChequesApi {
  ChequesApi(this._dio);

  final Dio _dio;

  Future<List<Cheque>> list({ChequeStatus? status}) => guardApi(() async {
    final response = await _dio.get<List<dynamic>>(
      '/cheques',
      queryParameters: {'status': ?status?.wire},
    );
    return [
      for (final c in response.data!)
        Cheque.fromJson(c as Map<String, dynamic>),
    ];
  });

  Future<Cheque> decide(
    Cheque cheque,
    ChequeStatus status, {
    required String clientMutationId,
    String? reason,
  }) => guardApi(() async {
    final response = await _dio.post<Map<String, dynamic>>(
      '/cheques/${cheque.isCustomer ? 'customer' : 'supplier'}/${cheque.id}/status',
      data: {
        'clientMutationId': clientMutationId,
        'status': status.wire,
        'reason': ?reason,
      },
    );
    return Cheque.fromJson(response.data!);
  });
}

final chequesApiProvider = Provider<ChequesApi>(
  (ref) => ChequesApi(ref.watch(dioClientProvider).dio),
);
