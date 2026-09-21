import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gestion_magasin/core/error/api_exception.dart';
import 'package:gestion_magasin/core/money.dart';
import 'package:gestion_magasin/data/models/page_meta.dart';
import 'package:gestion_magasin/features/audit/application/audit_controller.dart';
import 'package:gestion_magasin/features/audit/data/audit_api.dart';
import 'package:gestion_magasin/features/audit/data/audit_models.dart';
import 'package:gestion_magasin/features/audit/presentation/audit_screen.dart';
import 'package:gestion_magasin/ui/navigation.dart';
import 'package:gestion_magasin/ui/theme/app_theme.dart';

import 'support/fakes.dart';

AuditEntry _entry({
  String id = 'e1',
  AuditAction action = AuditAction.update,
  String entityType = 'ProductPrice',
  Map<String, dynamic>? oldValue,
  Map<String, dynamic>? newValue,
  String? userName = 'Radhi Badache',
}) => AuditEntry(
  id: id,
  userId: 'a',
  userName: userName,
  action: action,
  entityType: entityType,
  entityId: 'p1',
  oldValue: oldValue ?? {'priceHt': 120000, 'priceTierId': 'detail'},
  newValue: newValue ?? {'priceHt': 135000, 'priceTierId': 'detail'},
  createdAt: DateTime.utc(2026, 9, 21, 13, 2),
);

/// Page 2 RETENUE jusqu'à ce que le test la libère : de quoi changer de
/// filtre pendant le chargement.
class _SlowAuditApi extends AuditApi {
  _SlowAuditApi() : super(Dio());

  final page2 = Completer<AuditPage>();

  @override
  Future<AuditPage> list({
    int page = 1,
    int limit = 50,
    String? entityType,
    AuditAction? action,
    String? from,
  }) async {
    if (page == 2) return page2.future;
    final tag = entityType ?? 'tout';
    return AuditPage(
      data: [for (var i = 0; i < 50; i++) _entry(id: '$tag$i')],
      meta: const PageMeta(page: 1, limit: 50, total: 51),
    );
  }
}

class _FakeAuditApi extends AuditApi {
  _FakeAuditApi(this.pages, {this.failure, this.failPage}) : super(Dio());

  /// Page qui échoue (les autres répondent) : « Afficher plus » en échec.
  final int? failPage;

  /// Pages servies dans l'ordre ; le total est celui de TOUTES les pages.
  final List<List<AuditEntry>> pages;
  final ApiException? failure;
  final List<
    ({int page, String? entityType, AuditAction? action, String? from})
  >
  calls = [];

  @override
  Future<AuditPage> list({
    int page = 1,
    int limit = 50,
    String? entityType,
    AuditAction? action,
    String? from,
  }) async {
    if (failure != null && (failPage == null || failPage == page)) {
      throw failure!;
    }
    calls.add((page: page, entityType: entityType, action: action, from: from));
    return AuditPage(
      data: page <= pages.length ? pages[page - 1] : const [],
      meta: PageMeta(
        page: page,
        limit: limit,
        total: pages.fold(0, (n, p) => n + p.length),
      ),
    );
  }
}

Future<_FakeAuditApi> _pump(
  WidgetTester tester, {
  List<List<AuditEntry>> pages = const [[]],
  ApiException? failure,
  int? failPage,
}) async {
  useScreenSize(tester, const Size(1200, 1400));
  final api = _FakeAuditApi(pages, failure: failure, failPage: failPage);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [auditApiProvider.overrideWithValue(api)],
      child: MaterialApp(
        theme: AppTheme.desktop(dark: true),
        home: const Scaffold(body: AuditScreen()),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return api;
}

void main() {
  group('auditChanges — ce que l’admin lit', () {
    test('seuls les champs qui ont CHANGÉ', () {
      final changes = auditChanges(
        {'name': 'Câble', 'sku': 'CAB-1', 'isActive': true},
        {'name': 'Câble 3G2,5', 'sku': 'CAB-1', 'isActive': false},
      );
      expect(changes, [
        (field: 'Nom', before: 'Câble', after: 'Câble 3G2,5'),
        (field: 'Actif', before: 'oui', after: 'non'),
      ]);
    });

    test(
      'un MONTANT tracé en centimes se lit en dinars, jamais « 120000 »',
      () {
        final changes = auditChanges({'priceHt': 120000}, {'priceHt': 135000});
        expect(changes.single.before, formatDA(120000));
        expect(changes.single.after, formatDA(135000));
        expect(changes.single.field, 'Prix HT');
      },
    );

    test('une quantité (tracée en chaîne) n’est PAS prise pour un montant', () {
      final changes = auditChanges(
        {'receivedQuantity': '12.500'},
        {'receivedQuantity': '15.000'},
      );
      expect(changes.single.after, '15.000');
    });

    test('création : pas d’avant ; annulation : pas d’après', () {
      final created = auditChanges(null, {'title': 'Compter'});
      expect(created.single, (field: 'Intitulé', before: '', after: 'Compter'));
      final cancelled = auditChanges({'title': 'Compter'}, null);
      expect(cancelled.single, (
        field: 'Intitulé',
        before: 'Compter',
        after: '',
      ));
    });

    test('une opération de sécurité se LIT, elle ne se déchiffre pas', () {
      final change = auditChanges(null, {
        'operation': 'REFRESH_TOKEN_REUSE_DETECTED',
      }).single;
      expect(change.field, 'Opération');
      expect(change.after, contains('Vol de session présumé'));
    });

    test('l’ÉCART DE CAISSE du rapport Z se lit en dinars', () {
      // Revue du 2026-09-21, bloquant B1 : `difference` restait en centimes.
      final change = auditChanges(
        {'expectedAmount': 1200000},
        {
          'expectedAmount': 1200000,
          'countedAmount': 1199500,
          'difference': -500,
        },
      );
      expect(
        change.firstWhere((c) => c.field == 'difference').after,
        formatDA(-500),
      );
    });

    test('les prix IMBRIQUÉS dans les lignes se lisent aussi en dinars', () {
      final change = auditChanges(null, {
        'lines': [
          {'receivedQuantity': '12.000', 'unitPriceHt': 45000},
          {'receivedQuantity': '3.500', 'unitPriceHt': 120000},
        ],
      }).single;
      expect(change.after, contains(formatDA(45000)));
      expect(change.after, contains(formatDA(120000)));
      expect(change.after, contains('Prix unitaire HT'));
      expect(change.after, isNot(contains('45000')));
      // Les quantités (chaînes) restent des quantités.
      expect(change.after, contains('12.000'));
    });

    test('listes jointes, absences en tiret, rien de changé → vide', () {
      expect(
        auditChanges(
          {'roles': []},
          {
            'roles': ['ADMIN', 'VENDEUR'],
          },
        ).single,
        (field: 'Rôles', before: '—', after: 'ADMIN, VENDEUR'),
      );
      expect(auditChanges({'a': 1}, {'a': 1}), isEmpty);
    });
  });

  testWidgets('le journal : objet, action, auteur, et le détail formaté', (
    tester,
  ) async {
    await _pump(
      tester,
      pages: [
        [_entry()],
      ],
    );
    expect(find.text('Prix · Modification'), findsOneWidget);
    expect(find.textContaining('Radhi Badache'), findsOneWidget);
    expect(find.textContaining('1 champ(s)'), findsOneWidget);

    await tester.tap(find.text('Prix · Modification'));
    await tester.pumpAndSettle();
    expect(find.text('Prix HT'), findsOneWidget);
    // Montants en dinars, jamais les centimes bruts.
    expect(
      find.text('${formatDA(120000)}  →  ${formatDA(135000)}'),
      findsOneWidget,
    );
    expect(find.textContaining('120000'), findsNothing);
  });

  testWidgets('une action du système est attribuée au « Système »', (
    tester,
  ) async {
    await _pump(
      tester,
      pages: [
        [
          _entry(
            userName: null,
            entityType: 'User',
            action: AuditAction.cancel,
          ),
        ],
      ],
    );
    expect(find.textContaining('Système'), findsOneWidget);
    expect(find.text('Compte · Annulation'), findsOneWidget);
  });

  testWidgets('les filtres partent au serveur : objet, action, période', (
    tester,
  ) async {
    final api = await _pump(
      tester,
      pages: [
        [_entry()],
      ],
    );
    // Par défaut : 7 derniers jours.
    expect(api.calls.last.from, isNotNull);

    await tester.tap(
      find.widgetWithText(DropdownButtonFormField<String?>, 'Tous les objets'),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Transfert').last);
    await tester.pumpAndSettle();
    expect(api.calls.last.entityType, 'Transfer');

    await tester.tap(
      find.widgetWithText(DropdownButtonFormField<AuditAction?>, 'Toutes'),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Annulation').last);
    await tester.pumpAndSettle();
    expect(api.calls.last.action, AuditAction.cancel);

    await tester.tap(find.text('Tout'));
    await tester.pumpAndSettle();
    expect(api.calls.last.from, isNull);
  });

  testWidgets('au-delà d’une page, « Afficher plus » charge la suite', (
    tester,
  ) async {
    final first = [for (var i = 0; i < 50; i++) _entry(id: 'a$i')];
    final second = [
      _entry(id: 'b0', entityType: 'Sale', action: AuditAction.cancel),
    ];
    final api = await _pump(tester, pages: [first, second]);

    final more = find.textContaining('Afficher plus (50 sur 51)');
    await tester.scrollUntilVisible(more, 300);
    await tester.tap(more);
    await tester.pumpAndSettle();

    expect(api.calls.last.page, 2);
    expect(find.text('Vente · Annulation'), findsOneWidget);
    // Tout est chargé : le bouton disparaît.
    expect(find.textContaining('Afficher plus'), findsNothing);
  });

  testWidgets('journal vide sur la période : l’écran le dit', (tester) async {
    await _pump(tester);
    expect(find.text('Aucune action sur la période'), findsOneWidget);
  });

  testWidgets('accès retiré entre-temps : l’erreur du serveur s’affiche', (
    tester,
  ) async {
    await _pump(
      tester,
      failure: const ApiException(
        statusCode: 403,
        code: 'FORBIDDEN_ROLE',
        message: 'Rôle insuffisant pour cette action',
      ),
    );
    // Le code est traduit par l'app (jamais le texte brut du serveur).
    expect(find.textContaining('pas les droits'), findsOneWidget);
  });

  test(
    'filtre changé PENDANT « Afficher plus » : l’ancienne page ne s’ajoute pas',
    () async {
      // Revue du 2026-09-21, bloquant B2 : la page 2 de l'ANCIEN filtre
      // s'ajoutait sous le nouveau — le journal montrait des entrées hors filtre.
      final api = _SlowAuditApi();
      final container = ProviderContainer(
        overrides: [auditApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      final keep = container.listen(auditProvider, (_, _) {});
      addTearDown(keep.close);
      await container.read(auditProvider.future);

      final loading = container.read(auditProvider.notifier).loadMore();
      container.read(auditFilterProvider.notifier).set((
        entityType: 'Transfer',
        action: null,
        period: AuditPeriod.week,
      ));
      final filtered = await container.read(auditProvider.future);
      expect(filtered.items.first.id, 'Transfer0');

      // L'ancienne page 2 arrive enfin…
      api.page2.complete(
        AuditPage(
          data: [_entry(id: 'ANCIEN-FILTRE')],
          meta: const PageMeta(page: 2, limit: 50, total: 51),
        ),
      );
      await loading;

      // … et n'a rien écrasé.
      final after = container.read(auditProvider).value!;
      expect(after.items.map((e) => e.id), isNot(contains('ANCIEN-FILTRE')));
      expect(after.items.first.id, 'Transfer0');
      expect(after.items, hasLength(50));
    },
  );

  testWidgets('« Afficher plus » en échec : la liste reste, l’échec se DIT', (
    tester,
  ) async {
    await _pump(
      tester,
      pages: [
        [for (var i = 0; i < 50; i++) _entry(id: 'a$i')],
        [_entry(id: 'b0')],
      ],
      failPage: 2,
      failure: const ApiException(statusCode: 0, message: 'hors ligne'),
    );
    final more = find.textContaining('Afficher plus (50 sur 51)');
    await tester.scrollUntilVisible(more, 300);
    await tester.tap(more);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Pas de connexion au serveur'), findsOneWidget);
    // Rien n'est perdu : le bouton est toujours là pour réessayer.
    expect(more, findsOneWidget);
  });

  test(
    'page qui se RECOUVRE (journal modifié pendant la lecture) : pas de doublon',
    () async {
      final api = _FakeAuditApi([
        [for (var i = 0; i < 50; i++) _entry(id: 'a$i')],
        // Une action faite entre-temps a décalé les pages : a49 revient.
        [_entry(id: 'a49'), _entry(id: 'b0')],
      ]);
      final container = ProviderContainer(
        overrides: [auditApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      final keep = container.listen(auditProvider, (_, _) {});
      addTearDown(keep.close);
      await container.read(auditProvider.future);
      await container.read(auditProvider.notifier).loadMore();

      final ids = container.read(auditProvider).value!.items.map((e) => e.id);
      expect(ids.where((id) => id == 'a49'), hasLength(1));
      expect(ids, contains('b0'));
    },
  );

  test('menu : « Historique » pour l’ADMIN seul', () {
    expect(
      destinationsFor(
        authUser(roles: const ['ADMIN'], permissions: const ['audit.read']),
      ).map((d) => d.label),
      contains('Historique'),
    );
    for (final role in ['VENDEUR', 'MAGASINIER']) {
      expect(
        destinationsFor(
          authUser(roles: [role], permissions: const ['audit.read']),
        ).map((d) => d.label),
        isNot(contains('Historique')),
      );
    }
  });
}
