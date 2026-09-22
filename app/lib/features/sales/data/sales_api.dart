import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/error/api_exception.dart';
import '../../../core/providers.dart';
import '../../payments/data/payment_models.dart';
import 'sales_models.dart';

/// Accès réseau Caisse / Ventes / Clients. Aucune règle ici : le serveur fixe
/// les prix, contrôle le stock, la caisse et le plafond de crédit.
class SalesApi {
  SalesApi(this._dio);

  final Dio _dio;

  // ── Caisse ──────────────────────────────────────────────────────────────
  Future<CashSession?> currentCashSession() {
    return guardApi(() async {
      final response = await _dio.get<Object?>('/cash-sessions/current');
      final data = response.data;
      // Pas de caisse ouverte : corps vide.
      return data is Map<String, dynamic> && data.isNotEmpty
          ? CashSession.fromJson(data)
          : null;
    });
  }

  Future<CashSession> openCashSession(Map<String, dynamic> body) =>
      _post('/cash-sessions', body, CashSession.fromJson);

  Future<CashSession> closeCashSession(String id, Map<String, dynamic> body) =>
      _post('/cash-sessions/$id/close', body, CashSession.fromJson);

  // ── Ventes ──────────────────────────────────────────────────────────────
  /// Corps d'une vente — le MÊME pour `POST /sales` et pour la file hors-ligne
  /// (payload `SALE`). Le client n'envoie JAMAIS de prix : produit + quantité ;
  /// `expectedTotalTtc` est le total encaissé, que le serveur recompare.
  static Map<String, dynamic> saleBody({
    required String clientMutationId,
    required String id,
    String? customerId,
    String? cashSessionId,
    required List<({String productId, String quantity})> lines,
    required int paidAmount,
    required int expectedTotalTtc,
    String? dueDate,
  }) => {
    'clientMutationId': clientMutationId,
    'id': id,
    'customerId': ?customerId,
    'cashSessionId': ?cashSessionId,
    'lines': [
      for (final line in lines)
        {'productId': line.productId, 'quantity': line.quantity},
    ],
    'paidAmount': paidAmount,
    'expectedTotalTtc': expectedTotalTtc,
    'dueDate': ?dueDate,
  };

  Future<Sale> createSale(Map<String, dynamic> body) =>
      _post('/sales', body, Sale.fromJson);

  Future<SalePage> sales({int limit = 50}) {
    return guardApi(() async {
      final response = await _dio.get<Map<String, dynamic>>(
        '/sales',
        queryParameters: {'limit': limit},
      );
      return SalePage.fromJson(response.data!);
    });
  }

  Future<Sale> issueInvoice(String saleId) =>
      _post('/sales/$saleId/invoice', null, Sale.fromJson);

  /// PDF généré serveur : facture A4 si facturée, sinon ticket 80 mm.
  Future<Uint8List> saleDocument(String saleId) {
    return guardApi(() async {
      final response = await _dio.get<List<int>>(
        '/sales/$saleId/pdf',
        options: Options(responseType: ResponseType.bytes),
      );
      return Uint8List.fromList(response.data!);
    });
  }

  // ── Clients ─────────────────────────────────────────────────────────────
  Future<CustomerPage> customers({String? query, int limit = 50}) {
    return guardApi(() async {
      final response = await _dio.get<Map<String, dynamic>>(
        '/customers',
        queryParameters: {'limit': limit, 'q': ?query},
      );
      return CustomerPage.fromJson(response.data!);
    });
  }

  Future<Customer> createCustomer({required String name, String? phone}) {
    return _post('/customers', {
      'name': name,
      'phone': ?phone,
    }, Customer.fromJson);
  }

  Future<void> payCustomer({
    required String clientMutationId,
    required String customerId,
    required int amount,
  }) {
    return guardApi(() async {
      await _dio.post<Object?>(
        '/payments/customer',
        data: {
          'clientMutationId': clientMutationId,
          'customerId': customerId,
          'amount': amount,
        },
      );
    });
  }

  // ── Caisses (ADMIN) ─────────────────────────────────────────────────────
  Future<CashSessionPage> cashSessions({int limit = 100}) {
    return guardApi(() async {
      final response = await _dio.get<Map<String, dynamic>>(
        '/cash-sessions',
        queryParameters: {'limit': limit},
      );
      return CashSessionPage.fromJson(response.data!);
    });
  }

  // ── Historique et contre-passation des règlements ──────────────────────
  Future<PaymentHistoryPage> customerPayments(String customerId) {
    return guardApi(() async {
      final response = await _dio.get<Map<String, dynamic>>(
        '/customers/$customerId/payments',
        queryParameters: {'limit': 200},
      );
      return PaymentHistoryPage.fromJson(response.data!);
    });
  }

  Future<void> reverseCustomerPayment(
    String paymentId, {
    required String clientMutationId,
    required String reason,
  }) {
    return guardApi(() async {
      await _dio.post<Object?>(
        '/payments/customer/$paymentId/reverse',
        data: {'clientMutationId': clientMutationId, 'reason': reason},
      );
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
}

final salesApiProvider = Provider<SalesApi>(
  (ref) => SalesApi(ref.watch(dioClientProvider).dio),
);
