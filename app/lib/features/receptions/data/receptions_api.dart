import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/error/api_exception.dart';
import '../../../core/file_export.dart';
import '../../../core/providers.dart';
import 'receptions_models.dart';

/// Accès réseau des réceptions. Aucune règle ici : le serveur refuse la
/// surlivraison, fige le TTC et fait avancer la commande.
class ReceptionsApi {
  ReceptionsApi(this._dio);

  final Dio _dio;

  Future<List<Reception>> list({String? purchaseOrderId, int limit = 50}) {
    return guardApi(() async {
      final response = await _dio.get<Map<String, dynamic>>(
        '/receptions',
        queryParameters: {'limit': limit, 'purchaseOrderId': ?purchaseOrderId},
      );
      return ReceptionPage.fromJson(response.data!).data;
    });
  }

  Future<Reception> create(Map<String, Object?> fields) {
    return guardApi(() async {
      final response = await _dio.post<Map<String, dynamic>>(
        '/receptions',
        data: fields,
      );
      return Reception.fromJson(response.data!);
    });
  }

  /// Lecture d'une photo de facture (P2 n°24) : lignes PROPOSÉES (`text`,
  /// `productId`, `productName`, `quantity`, `unitPriceHt`), jamais
  /// enregistrées.
  Future<List<Map<String, dynamic>>> scanInvoice(Uint8List jpeg) {
    return guardApi(() async {
      final response = await _dio.post<Map<String, dynamic>>(
        '/receptions/scan-invoice',
        data: FormData.fromMap({
          'image': MultipartFile.fromBytes(jpeg, filename: 'facture.jpg'),
        }),
        // La lecture prend quelques secondes sur le serveur.
        options: Options(receiveTimeout: const Duration(seconds: 90)),
      );
      return [
        for (final l in response.data!['lines'] as List<dynamic>)
          l as Map<String, dynamic>,
      ];
    });
  }

  /// Bons de réception des 12 derniers mois.
  Future<ExportedFile> exportReceptions(ExportFormat format) {
    final window = recentWindow(365);
    return fetchExport(
      _dio,
      '/receptions/export',
      format,
      query: {'from': window.from, 'to': window.to},
    );
  }
}

final receptionsApiProvider = Provider<ReceptionsApi>(
  (ref) => ReceptionsApi(ref.watch(dioClientProvider).dio),
);
