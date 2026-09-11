import 'package:freezed_annotation/freezed_annotation.dart';

part 'page_meta.freezed.dart';
part 'page_meta.g.dart';

/// `{ page, limit, total }` — enveloppe de TOUTE liste paginée (CONVENTIONS.md
/// § Pagination). Partagée par les features : chaque liste l'embarque.
@freezed
abstract class PageMeta with _$PageMeta {
  const PageMeta._();

  const factory PageMeta({
    required int page,
    required int limit,
    required int total,
  }) = _PageMeta;

  factory PageMeta.fromJson(Map<String, dynamic> json) =>
      _$PageMetaFromJson(json);

  /// Reste-t-il des éléments au-delà de ceux déjà chargés ?
  bool hasMoreAfter(int loaded) => loaded < total;
}
