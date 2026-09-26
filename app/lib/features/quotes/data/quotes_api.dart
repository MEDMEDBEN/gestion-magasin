import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/error/api_exception.dart';
import '../../../core/providers.dart';
import '../../sales/data/sales_models.dart';
import 'quote_models.dart';

/// Devis (spec §8quater). EN LIGNE uniquement : un devis se numérote et
/// change d'état sur le serveur, et sa conversion est une vente complète qui
/// doit être jugée au moment où elle a lieu.
class QuotesApi {
  QuotesApi(this._dio);

  final Dio _dio;

  Future<QuotePage> list({QuoteStatus? status, int limit = 100}) {
    return guardApi(() async {
      final response = await _dio.get<Map<String, dynamic>>(
        '/quotes',
        queryParameters: {
          'limit': limit,
          if (status != null && status != QuoteStatus.unknown)
            'status': _wire(status),
        },
      );
      return QuotePage.fromJson(response.data!);
    });
  }

  /// Lignes du panier : produit, quantité, et le prix seulement s'il a été
  /// modifié — le serveur applique le tarif du client et le plancher.
  Future<Quote> create({
    required String id,
    String? customerId,
    String? validUntil,
    required List<({String productId, String quantity, int? unitPriceHt})>
    lines,
  }) => _post('/quotes', {
    'id': id,
    'customerId': ?customerId,
    'validUntil': ?validUntil,
    'lines': [
      for (final line in lines)
        {
          'productId': line.productId,
          'quantity': line.quantity,
          if (line.unitPriceHt != null) ...{
            'unitPriceHt': line.unitPriceHt,
            'priceEdited': true,
          },
        },
    ],
  }, Quote.fromJson);

  Future<Quote> send(String id) =>
      _post('/quotes/$id/send', null, Quote.fromJson);

  Future<Quote> accept(String id) =>
      _post('/quotes/$id/accept', null, Quote.fromJson);

  Future<Quote> refuse(String id) =>
      _post('/quotes/$id/refuse', null, Quote.fromJson);

  /// Devis accepté → vente. Mutation d'ARGENT : clé d'intention stable.
  Future<Sale> convert(
    String id, {
    required String clientMutationId,
    required int paidAmount,
    required int expectedTotalTtc,
    String? cashSessionId,
    String? dueDate,
  }) => _post('/quotes/$id/convert', {
    'clientMutationId': clientMutationId,
    'paidAmount': paidAmount,
    'expectedTotalTtc': expectedTotalTtc,
    'cashSessionId': ?cashSessionId,
    'dueDate': ?dueDate,
  }, Sale.fromJson);

  Future<Uint8List> document(String id) {
    return guardApi(() async {
      final response = await _dio.get<List<int>>(
        '/quotes/$id/pdf',
        options: Options(responseType: ResponseType.bytes),
      );
      return Uint8List.fromList(response.data!);
    });
  }

  Future<T> _post<T>(
    String path,
    Map<String, Object?>? data,
    T Function(Map<String, dynamic>) decode,
  ) {
    return guardApi(() async {
      final response = await _dio.post<Map<String, dynamic>>(path, data: data);
      return decode(response.data!);
    });
  }

  static String _wire(QuoteStatus status) => switch (status) {
    QuoteStatus.draft => 'BROUILLON',
    QuoteStatus.sent => 'ENVOYE',
    QuoteStatus.accepted => 'ACCEPTE',
    QuoteStatus.converted => 'CONVERTI',
    QuoteStatus.refused => 'REFUSE',
    QuoteStatus.expired => 'EXPIRE',
    QuoteStatus.unknown => '',
  };
}

final quotesApiProvider = Provider<QuotesApi>(
  (ref) => QuotesApi(ref.watch(dioClientProvider).dio),
);
