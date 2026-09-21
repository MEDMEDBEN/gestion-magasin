import 'package:decimal/decimal.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gestion_magasin/data/models/page_meta.dart';
import 'package:gestion_magasin/features/auth/data/auth_models.dart';
import 'package:gestion_magasin/features/catalog/application/catalog_controller.dart';
import 'package:gestion_magasin/features/transfers/data/transfers_api.dart';
import 'package:gestion_magasin/features/transfers/data/transfers_models.dart';
import 'package:gestion_magasin/features/transfers/presentation/transfers_screen.dart';
import 'package:gestion_magasin/ui/navigation.dart';
import 'package:gestion_magasin/ui/theme/app_theme.dart';

import 'support/catalog_fakes.dart';
import 'support/fakes.dart';

Transfer _transfer(
  TransferStatus status, {
  String requestedById = 'v',
  String prepared = '0',
  String shipped = '0',
  String received = '0',
}) => Transfer(
  id: 't1',
  number: 'TRF-2026-00004',
  status: status,
  priority: TransferPriority.urgent,
  fromLocationId: 'depot',
  toLocationId: 'magasin',
  requestedById: requestedById,
  requestedAt: DateTime.utc(2026, 9, 21),
  updatedAt: DateTime.utc(2026, 9, 21),
  lines: [
    TransferLine(
      id: 'l1',
      productId: 'p1',
      requestedQuantity: Decimal.fromInt(20),
      preparedQuantity: Decimal.parse(prepared),
      shippedQuantity: Decimal.parse(shipped),
      receivedQuantity: Decimal.parse(received),
    ),
  ],
);

class _FakeTransfersApi extends TransfersApi {
  _FakeTransfersApi(this.transfers) : super(Dio());

  final List<Transfer> transfers;
  Map<String, Object?>? created;
  Map<String, Object?>? prepared;
  Map<String, Object?>? receivedFields;
  String? shippedId;
  String? acceptedId;
  String? closedStatus;

  @override
  Future<TransferPage> list({String? status, int limit = 200}) async =>
      TransferPage(
        data: transfers,
        meta: PageMeta(page: 1, limit: limit, total: transfers.length),
      );

  @override
  Future<Transfer> create(Map<String, Object?> fields) async {
    created = fields;
    return _transfer(TransferStatus.requested);
  }

  @override
  Future<Transfer> prepare(String id, Map<String, Object?> fields) async {
    prepared = fields;
    return _transfer(TransferStatus.prepared, prepared: '18');
  }

  @override
  Future<Transfer> accept(String id) async {
    acceptedId = id;
    return _transfer(TransferStatus.accepted);
  }

  @override
  Future<Transfer> ship(String id) async {
    shippedId = id;
    return _transfer(TransferStatus.inTransit, prepared: '18', shipped: '18');
  }

  @override
  Future<Transfer> receive(String id, Map<String, Object?> fields) async {
    receivedFields = fields;
    return _transfer(
      TransferStatus.received,
      prepared: '18',
      shipped: '18',
      received: '15',
    );
  }

  @override
  Future<Transfer> cancel(String id, String status) async {
    closedStatus = status;
    return _transfer(
      status == 'REFUSEE' ? TransferStatus.refused : TransferStatus.cancelled,
    );
  }
}

AuthUser _vendeur({String id = 'v'}) => authUser(
  id: id,
  roles: const ['VENDEUR'],
  permissions: const [
    'transfer.request',
    'transfer.receive',
    'transfer.cancel',
  ],
);

AuthUser _magasinier() => authUser(
  id: 'm',
  roles: const ['MAGASINIER'],
  permissions: const ['transfer.prepare', 'transfer.cancel'],
);

Future<_FakeTransfersApi> _pump(
  WidgetTester tester,
  AuthUser user, {
  List<Transfer> transfers = const [],
}) async {
  useScreenSize(tester, const Size(500, 1400));
  final api = _FakeTransfersApi(transfers);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        transfersApiProvider.overrideWithValue(api),
        activeProductsProvider.overrideWith(
          (ref) => Stream.value([
            product(id: 'p1', name: 'Câble 3G2,5', sku: 'CAB-3G25'),
          ]),
        ),
      ],
      child: MaterialApp(
        theme: AppTheme.mobile(dark: true),
        home: Scaffold(body: TransfersScreen(user: user)),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return api;
}

void main() {
  testWidgets('le vendeur demande : produit, quantité et priorité partent', (
    tester,
  ) async {
    final api = await _pump(tester, _vendeur());

    await tester.tap(find.text('Nouvelle demande'));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(DropdownButtonFormField<TransferPriority>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Urgente').last);
    await tester.pumpAndSettle();

    await tester.tap(find.byType(DropdownButtonFormField<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Câble 3G2,5 · CAB-3G25').last);
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Quantité demandée'),
      '12,5',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Envoyer la demande'));
    await tester.pumpAndSettle();

    expect(api.created, containsPair('priority', 'URGENTE'));
    expect(api.created!['lines'], [
      {'productId': 'p1', 'quantity': '12.500'},
    ]);
    // Clé d'idempotence : un renvoi ne crée pas une seconde demande.
    expect(api.created!['clientMutationId'], isA<String>());
  });

  testWidgets('demande vide : rien ne part', (tester) async {
    final api = await _pump(tester, _vendeur());
    await tester.tap(find.text('Nouvelle demande'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Envoyer la demande'));
    await tester.pumpAndSettle();

    expect(find.text('Choisissez un produit'), findsOneWidget);
    expect(api.created, isNull);
  });

  testWidgets('le dépôt accepte la demande avant de la préparer', (
    tester,
  ) async {
    final api = await _pump(
      tester,
      _magasinier(),
      transfers: [_transfer(TransferStatus.requested)],
    );
    await tester.tap(find.textContaining('TRF-2026-00004'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Accepter la demande'));
    await tester.pumpAndSettle();

    expect(api.acceptedId, 't1');
    expect(find.textContaining('Acceptée'), findsWidgets);
  });

  testWidgets('une demande déjà acceptée ne se ré-accepte pas', (tester) async {
    await _pump(
      tester,
      _magasinier(),
      transfers: [_transfer(TransferStatus.accepted)],
    );
    await tester.tap(find.textContaining('TRF-2026-00004'));
    await tester.pumpAndSettle();
    expect(find.text('Accepter la demande'), findsNothing);
  });

  testWidgets('le magasinier prépare : la quantité saisie part au serveur', (
    tester,
  ) async {
    final api = await _pump(
      tester,
      _magasinier(),
      transfers: [_transfer(TransferStatus.accepted)],
    );
    // La liste affiche un AVANCEMENT lisible, pas du code.
    expect(find.textContaining('TRF-2026-00004'), findsOneWidget);
    expect(find.textContaining('20 demandés'), findsOneWidget);
    expect(find.textContaining('priorité urgente'), findsOneWidget);

    await tester.tap(find.textContaining('TRF-2026-00004'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Préparer la marchandise'));
    await tester.pumpAndSettle();

    // Le plafond du serveur est annoncé dans l'écran.
    expect(find.textContaining('Demandé 20'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Quantité préparée'),
      '18',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Enregistrer la préparation'));
    await tester.pumpAndSettle();

    expect(api.prepared, containsPair('done', true));
    expect(api.prepared!['lines'], [
      {'productId': 'p1', 'preparedQuantity': '18.000'},
    ]);
  });

  testWidgets('préparer plus que demandé : refusé avant l’envoi', (
    tester,
  ) async {
    final api = await _pump(
      tester,
      _magasinier(),
      transfers: [_transfer(TransferStatus.accepted)],
    );
    await tester.tap(find.textContaining('TRF-2026-00004'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Préparer la marchandise'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Quantité préparée'),
      '21',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Enregistrer la préparation'));
    await tester.pumpAndSettle();

    expect(find.text('Au plus 20'), findsOneWidget);
    expect(api.prepared, isNull);
  });

  testWidgets('« Enregistrer en cours » garde la préparation ouverte', (
    tester,
  ) async {
    final api = await _pump(
      tester,
      _magasinier(),
      transfers: [_transfer(TransferStatus.preparing, prepared: '5')],
    );
    await tester.tap(find.textContaining('TRF-2026-00004'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Préparer la marchandise'));
    await tester.pumpAndSettle();

    // Reprise : la quantité déjà préparée est proposée, pas le demandé.
    expect(find.widgetWithText(TextFormField, '5'), findsOneWidget);
    await tester.tap(find.text('Enregistrer en cours'));
    await tester.pumpAndSettle();
    expect(api.prepared, containsPair('done', false));
  });

  testWidgets('expédition : confirmation demandée avant que le stock parte', (
    tester,
  ) async {
    final api = await _pump(
      tester,
      _magasinier(),
      transfers: [_transfer(TransferStatus.prepared, prepared: '18')],
    );
    await tester.tap(find.textContaining('TRF-2026-00004'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Expédier vers le magasin'));
    await tester.pumpAndSettle();

    expect(find.textContaining('ne s’annule plus'), findsOneWidget);
    await tester.tap(find.text('Expédier'));
    await tester.pumpAndSettle();
    expect(api.shippedId, 't1');
  });

  testWidgets('le vendeur réceptionne : l’écart part tel qu’il l’a compté', (
    tester,
  ) async {
    final api = await _pump(
      tester,
      _vendeur(),
      transfers: [
        _transfer(TransferStatus.inTransit, prepared: '18', shipped: '18'),
      ],
    );
    expect(find.textContaining('en transit 18 sur 20 demandés'), findsOneWidget);

    await tester.tap(find.textContaining('TRF-2026-00004'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Réceptionner au magasin'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Expédié 18'), findsOneWidget);
    expect(find.textContaining('retourne au'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Quantité reçue au magasin'),
      '15',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Enregistrer la réception'));
    await tester.pumpAndSettle();

    expect(api.receivedFields!['lines'], [
      {'productId': 'p1', 'receivedQuantity': '15.000'},
    ]);
  });

  testWidgets('le dépôt REFUSE, il n’annule pas la demande d’autrui', (
    tester,
  ) async {
    final depot = await _pump(
      tester,
      _magasinier(),
      transfers: [_transfer(TransferStatus.requested)],
    );
    await tester.tap(find.textContaining('TRF-2026-00004'));
    await tester.pumpAndSettle();
    expect(find.text('Annuler ma demande'), findsNothing);
    await tester.tap(find.text('Refuser la demande'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Refuser'));
    await tester.pumpAndSettle();
    expect(depot.closedStatus, 'REFUSEE');
  });

  testWidgets('un autre vendeur ne voit pas l’annulation d’un collègue', (
    tester,
  ) async {
    await _pump(
      tester,
      _vendeur(id: 'autre'),
      transfers: [_transfer(TransferStatus.requested)],
    );
    await tester.tap(find.textContaining('TRF-2026-00004'));
    await tester.pumpAndSettle();
    expect(find.text('Annuler ma demande'), findsNothing);
    expect(find.text('Refuser la demande'), findsNothing);
  });

  testWidgets('l’AUTEUR de la demande l’annule', (tester) async {
    final auteur = await _pump(
      tester,
      _vendeur(),
      transfers: [_transfer(TransferStatus.requested)],
    );
    await tester.tap(find.textContaining('TRF-2026-00004'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Annuler ma demande'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Annuler la demande'));
    await tester.pumpAndSettle();
    expect(auteur.closedStatus, 'ANNULEE');
  });

  testWidgets('marchandise partie ou reçue : plus d’abandon proposé', (
    tester,
  ) async {
    await _pump(
      tester,
      _vendeur(),
      transfers: [
        _transfer(TransferStatus.inTransit, prepared: '18', shipped: '18'),
      ],
    );
    await tester.tap(find.textContaining('TRF-2026-00004'));
    await tester.pumpAndSettle();
    expect(find.text('Annuler ma demande'), findsNothing);
    expect(find.text('Réceptionner au magasin'), findsOneWidget);
  });

  testWidgets('« Voir les lignes » montre les quantités FORMATÉES', (
    tester,
  ) async {
    await _pump(
      tester,
      _vendeur(),
      transfers: [
        _transfer(
          TransferStatus.received,
          prepared: '18',
          shipped: '18',
          received: '15',
        ),
      ],
    );
    await tester.tap(find.textContaining('TRF-2026-00004'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Voir les lignes'));
    await tester.pumpAndSettle();

    expect(find.text('Câble 3G2,5'), findsOneWidget);
    expect(
      find.text('Demandé 20 · préparé 18 · expédié 18 · reçu 15'),
      findsOneWidget,
    );
  });

  testWidgets('un transfert reçu AVEC ÉCART ne passe pas pour nickel', (
    tester,
  ) async {
    await _pump(
      tester,
      _vendeur(),
      transfers: [
        _transfer(
          TransferStatus.received,
          prepared: '18',
          shipped: '18',
          received: '15',
        ),
      ],
    );
    expect(find.text('Reçue · écart'), findsOneWidget);
    expect(find.textContaining('le manquant est rentré au dépôt'), findsOneWidget);
  });

  testWidgets('un transfert reçu en ENTIER reste un simple « Reçue »', (
    tester,
  ) async {
    await _pump(
      tester,
      _vendeur(),
      transfers: [
        _transfer(
          TransferStatus.received,
          prepared: '18',
          shipped: '18',
          received: '18',
        ),
      ],
    );
    expect(find.text('Reçue'), findsOneWidget);
    expect(find.textContaining('ÉCART'), findsNothing);
  });

  test('menu : « Transferts » pour qui tient un bout du flux', () {
    for (final user in [_vendeur(), _magasinier()]) {
      expect(
        destinationsFor(user).map((d) => d.label),
        contains('Transferts'),
      );
    }
    // Un compte sans aucun droit de transfert ne voit pas l'entrée.
    expect(
      destinationsFor(
        authUser(roles: const ['VENDEUR'], permissions: const ['sale.create']),
      ).map((d) => d.label),
      isNot(contains('Transferts')),
    );
  });
}
