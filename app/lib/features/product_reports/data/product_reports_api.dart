import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/error/api_exception.dart';
import '../../../core/providers.dart';
import 'product_report_models.dart';

/// Rapports produits (spec §20). Lecture seule : ces écrans ne décident rien,
/// ils font voir.
class ProductReportsApi {
  ProductReportsApi(this._dio);

  final Dio _dio;

  /// `limit` est FIXÉ ici, pas paramétrable : l'écran montre une page et annonce
  /// le reste. Le jour où il faudra dérouler, c'est `page` qu'il faudra ajouter,
  /// pas une limite variable.
  static const pageSize = 50;

  Future<DormantProductPage> dormant({int days = 120}) {
    return guardApi(() async {
      final response = await _dio.get<Map<String, dynamic>>(
        '/reports/dormant-products',
        queryParameters: {'days': days, 'limit': pageSize},
      );
      return DormantProductPage.fromJson(response.data!);
    });
  }

  Future<ProductDemand> demand({int days = 30}) {
    return guardApi(() async {
      final response = await _dio.get<Map<String, dynamic>>(
        '/reports/product-demand',
        queryParameters: {'days': days},
      );
      return ProductDemand.fromJson(response.data!);
    });
  }
}

final productReportsApiProvider = Provider<ProductReportsApi>(
  (ref) => ProductReportsApi(ref.watch(dioClientProvider).dio),
);
