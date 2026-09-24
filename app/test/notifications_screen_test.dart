import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gestion_magasin/core/providers.dart';
import 'package:gestion_magasin/data/models/page_meta.dart';
import 'package:gestion_magasin/features/auth/data/auth_models.dart';
import 'package:gestion_magasin/features/notifications/data/notification_models.dart';
import 'package:gestion_magasin/features/notifications/data/notifications_api.dart';
import 'package:gestion_magasin/features/notifications/presentation/notifications_screen.dart';
import 'package:gestion_magasin/ui/navigation.dart';
import 'package:gestion_magasin/ui/theme/app_theme.dart';
import 'package:gestion_magasin/ui/theme/ampere_colors.dart';

import 'support/fakes.dart';

/// Notifications (P1 n°16) : une alerte se TRAITE — elle se marque lue et ouvre
/// l'opération concernée, quand ce compte y a droit.
class _FakeNotificationsApi extends NotificationsApi {
  _FakeNotificationsApi(this.items) : super(Dio());

  List<AppNotification> items;
  final read = <String>[];
  int allReadCalls = 0;

  int get unread => items.where((n) => !n.isRead).length;

  @override
  Future<NotificationPage> list({
    int page = 1,
    int limit = 30,
    bool unreadOnly = false,
  }) async => NotificationPage(
    data: unreadOnly ? items.where((n) => !n.isRead).toList() : items,
    meta: PageMeta(page: page, limit: limit, total: items.length),
    unread: unread,
  );

  @override
  Future<int> markRead(String id) async {
    read.add(id);
    items = [for (final n in items) n.id == id ? n.copyWith(isRead: true) : n];
    return unread;
  }

  @override
  Future<int> markAllRead() async {
    allReadCalls++;
    items = [for (final n in items) n.copyWith(isRead: true)];
    return 0;
  }
}

AppNotification _notification({
  String id = 'n1',
  NotificationKind type = NotificationKind.transferRequested,
  String title = 'Demande TRF-2026-00007 à préparer',
  bool isRead = false,
  NotificationTarget? target = NotificationTarget.transfer,
  NotificationPriority priority = NotificationPriority.normal,
}) => AppNotification(
  id: id,
  type: type,
  priority: priority,
  title: title,
  body: '3 produit(s) demandé(s)',
  isRead: isRead,
  operationType: target,
  operationId: 'op-1',
  createdAt: DateTime.utc(2026, 9, 23, 9),
);

AuthUser _magasinier() => authUser(
  id: 'm',
  fullName: 'Karim Ould',
  roles: const ['MAGASINIER'],
  permissions: const ['transfer.prepare', 'product.read'],
);

Future<(_FakeNotificationsApi, WidgetRef)> _pump(
  WidgetTester tester, {
  required List<AppNotification> items,
  AuthUser? user,
}) async {
  useScreenSize(tester, const Size(500, 1400));
  final api = _FakeNotificationsApi(items);
  late WidgetRef capturedRef;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        notificationsApiProvider.overrideWithValue(api),
        // Session ouverte : sans elle, l'écran ne lit RIEN (garde « poste
        // partagé » — la boîte du compte précédent ne doit pas rester à l'écran).
        currentUserIdProvider.overrideWithValue('m'),
      ],
      child: MaterialApp(
        theme: AppTheme.mobile(dark: true),
        home: Consumer(
          builder: (context, ref, _) {
            capturedRef = ref;
            return Scaffold(
              body: NotificationsScreen(user: user ?? _magasinier()),
            );
          },
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (api, capturedRef);
}

void main() {
  testWidgets('la boîte vide le DIT, elle ne reste pas blanche', (
    tester,
  ) async {
    await _pump(tester, items: const []);

    expect(find.text('Aucune notification'), findsOneWidget);
    expect(find.text('Tout marquer lu (0)'), findsNothing);
  });

  testWidgets('toucher une alerte la marque lue ET ouvre l’opération', (
    tester,
  ) async {
    final (api, ref) = await _pump(tester, items: [_notification()]);

    await tester.tap(find.text('Demande TRF-2026-00007 à préparer'));
    await tester.pumpAndSettle();

    expect(api.read, ['n1']);
    expect(ref.read(requestedDestinationProvider), 'Transferts');
  });

  testWidgets('une alerte DÉJÀ lue n’est pas remarquée lue une seconde fois', (
    tester,
  ) async {
    final (api, _) = await _pump(tester, items: [_notification(isRead: true)]);

    await tester.tap(find.text('Demande TRF-2026-00007 à préparer'));
    await tester.pumpAndSettle();

    expect(api.read, isEmpty);
  });

  /// Le compte n'a pas l'écran Achats : la carte informe, elle n'ouvre rien —
  /// un bouton mort est pire qu'une simple ligne.
  testWidgets('aucune ouverture vers un écran fermé à ce compte', (
    tester,
  ) async {
    final (api, ref) = await _pump(
      tester,
      items: [
        _notification(
          type: NotificationKind.partialReception,
          title: 'Réception partielle BR-2026-00003',
          target: NotificationTarget.reception,
        ),
      ],
    );

    await tester.tap(find.text('Réception partielle BR-2026-00003'));
    await tester.pumpAndSettle();

    // Lue quand même : l'information a bien été vue.
    expect(api.read, ['n1']);
    expect(ref.read(requestedDestinationProvider), isNull);
  });

  testWidgets('« Tout marquer lu » vide le compteur en un appel', (
    tester,
  ) async {
    final (api, _) = await _pump(
      tester,
      items: [
        _notification(),
        _notification(id: 'n2', title: 'Transfert TRF-2026-00008 en route'),
      ],
    );

    expect(find.text('Tout marquer lu (2)'), findsOneWidget);
    await tester.tap(find.text('Tout marquer lu (2)'));
    await tester.pumpAndSettle();

    expect(api.allReadCalls, 1);
    expect(find.textContaining('Tout marquer lu'), findsNothing);
  });

  /// Le serveur peut ajouter un type d'alerte avant que l'app ne soit mise à
  /// jour. Sans repli, une SEULE valeur inconnue faisait échouer le décodage de
  /// toute la boîte — badge compris (régression P1 n°17, écran P1 n°16 cassé).
  test('une alerte d’un type inconnu se décode au lieu de tout casser', () {
    final json = {
      'id': 'n9',
      'type': 'TYPE_QUI_N_EXISTE_PAS_ENCORE',
      'priority': 'PRIORITE_INCONNUE',
      'title': 'Quelque chose est arrivé',
      'body': null,
      'isRead': false,
      'readAt': null,
      'operationType': 'OPERATION_INCONNUE',
      'operationId': 'op-9',
      'createdAt': '2026-09-24T09:00:00.000Z',
    };

    final parsed = AppNotification.fromJson(json);

    expect(parsed.type, NotificationKind.unknown);
    expect(parsed.operationType, NotificationTarget.unknown);
    expect(parsed.title, 'Quelque chose est arrivé');
    // Inconnue : lisible, mais elle n'ouvre aucun écran.
    expect(destinationFor(parsed.operationType), isNull);
  });

  test('les types livrés avec la messagerie sont reconnus', () {
    final parsed = AppNotification.fromJson({
      'id': 'n10',
      'type': 'MESSAGE',
      'priority': 'NORMALE',
      'title': 'Rupture câbles',
      'isRead': false,
      'operationType': 'CONVERSATION',
      'operationId': 'c1',
      'createdAt': '2026-09-24T09:00:00.000Z',
    });

    expect(parsed.type, NotificationKind.message);
    expect(destinationFor(parsed.operationType), 'Messages');
  });

  testWidgets('une alerte urgente se distingue des autres', (tester) async {
    expect(
      toneOf(_notification(priority: NotificationPriority.urgent)),
      StatusTone.error,
    );
    expect(
      toneOf(_notification(type: NotificationKind.lowStock)),
      StatusTone.warn,
    );
  });
}
