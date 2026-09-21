import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/dates.dart';
import '../../../core/providers.dart';
import '../data/audit_api.dart';
import '../data/audit_models.dart';

/// Période affichée : le journal grossit vite, « tout » n'est qu'un choix.
enum AuditPeriod {
  week('7 jours', 7),
  month('30 jours', 30),
  all('Tout', null);

  const AuditPeriod(this.label, this.days);
  final String label;
  final int? days;

  /// Premier jour inclus, `AAAA-MM-JJ` (jour civil, heure du poste).
  String? get from => days == null
      ? null
      : isoDay(DateTime.now().subtract(Duration(days: days! - 1)));
}

/// Filtres de l'écran. `null` = pas de filtre.
typedef AuditFilter = ({
  String? entityType,
  AuditAction? action,
  AuditPeriod period,
});

class AuditFilterController extends Notifier<AuditFilter> {
  @override
  AuditFilter build() =>
      (entityType: null, action: null, period: AuditPeriod.week);

  void set(AuditFilter filter) => state = filter;
}

final auditFilterProvider =
    NotifierProvider.autoDispose<AuditFilterController, AuditFilter>(
      AuditFilterController.new,
    );

@immutable
class AuditListState {
  const AuditListState({
    required this.items,
    required this.total,
    required this.page,
    this.isLoadingMore = false,
  });

  final List<AuditEntry> items;

  /// Total côté serveur : le journal peut dépasser ce qui est chargé, et
  /// l'écran le dit au lieu de tronquer en silence.
  final int total;
  final int page;
  final bool isLoadingMore;

  bool get hasMore => items.length < total;
}

/// Journal chargé page après page, lu EN LIGNE et lié au compte connecté :
/// rien du journal ne reste en mémoire après une déconnexion.
class AuditController extends AsyncNotifier<AuditListState> {
  static const pageSize = 50;

  @override
  Future<AuditListState> build() async {
    ref.watch(currentUserIdProvider);
    final page = await _fetch(ref.watch(auditFilterProvider), 1);
    return AuditListState(items: page.data, total: page.meta.total, page: 1);
  }

  Future<AuditPage> _fetch(AuditFilter filter, int page) => ref
      .read(auditApiProvider)
      .list(
        page: page,
        limit: pageSize,
        entityType: filter.entityType,
        action: filter.action,
        from: filter.period.from,
      );

  Future<void> loadMore() async {
    final current = state.value;
    if (current == null || !current.hasMore || current.isLoadingMore) return;
    state = AsyncData(
      AuditListState(
        items: current.items,
        total: current.total,
        page: current.page,
        isLoadingMore: true,
      ),
    );
    // Le filtre en vigueur AU DÉPART de l'appel : si l'admin en change pendant
    // le chargement, la page qui revient appartient à l'ancien filtre et ne
    // doit JAMAIS s'ajouter sous le nouveau (revue du 2026-09-21, bloquant B2).
    final filter = ref.read(auditFilterProvider);
    bool stale() => !ref.mounted || ref.read(auditFilterProvider) != filter;
    try {
      final next = await _fetch(filter, current.page + 1);
      if (stale()) return;
      // Pagination par décalage sur un journal trié du plus récent : une action
      // faite pendant la lecture décale les pages. On ne montre pas deux fois
      // la même entrée.
      final seen = {for (final e in current.items) e.id};
      state = AsyncData(
        AuditListState(
          items: [
            ...current.items,
            for (final e in next.data)
              if (!seen.contains(e.id)) e,
          ],
          total: next.meta.total,
          page: current.page + 1,
        ),
      );
    } catch (_) {
      if (stale()) return;
      state = AsyncData(current);
      rethrow;
    }
  }
}

final auditProvider =
    AsyncNotifierProvider.autoDispose<AuditController, AuditListState>(
      AuditController.new,
    );
