import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/error/api_exception.dart';
import '../../../core/providers.dart';
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

  Future<CashSession> openCashSession({
    required String locationId,
    required int openingFloat,
  }) {
    return _post('/cash-sessions', {
      'locationId': locationId,
      'openingFloat': openingFloat,
    }, CashSession.fromJson);
  }

  Future<CashSession> closeCashSession(
    String id, {
    required int countedAmount,
    String? note,
  }) {
    return _post('/cash-sessions/$id/close', {
      'countedAmount': countedAmount,
      'note': ?note,
    }, CashSession.fromJson);
  }

  // ── Ventes ──────────────────────────────────────────────────────────────
  /// Le client n'envoie JAMAIS de prix : produit + quantité (+ remise ADMIN).
  Future<Sale> createSale({
    required String id,
    String? customerId,
    required List<({String productId, String quantity})> lines,
    required int paidAmount,
    int? expectedTotalTtc,
  }) {
    return _post('/sales', {
      'expectedTotalTtc': ?expectedTotalTtc,
      'id': id,
      'customerId': ?customerId,
      'lines': [
        for (final line in lines)
          {'productId': line.productId, 'quantity': line.quantity},
      ],
      'paidAmount': paidAmount,
    }, Sale.fromJson);
  }

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
    required String id,
    required String customerId,
    required int amount,
  }) {
    return guardApi(() async {
      await _dio.post<Object?>(
        '/payments/customer',
        data: {'id': id, 'customerId': customerId, 'amount': amount},
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
