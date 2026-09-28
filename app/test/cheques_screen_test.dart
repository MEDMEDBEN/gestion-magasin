import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gestion_magasin/core/money.dart';
import 'package:gestion_magasin/core/providers.dart';
import 'package:gestion_magasin/features/cheques/data/cheques_api.dart';
import 'package:gestion_magasin/features/cheques/presentation/cheques_screen.dart';
import 'package:gestion_magasin/ui/navigation.dart';
import 'package:gestion_magasin/ui/theme/app_theme.dart';

import 'support/fakes.dart';

Cheque _cheque(String id, {String kind = 'CLIENT'}) => Cheque(
  id: id,
  kind: kind,
  partyId: 'p',
  partyName: kind == 'CLIENT' ? 'Électricité Benali' : 'Sonelec',
  amount: 40000,
  number: 'C-$id',
  bank: 'BNA',
  dueDate: '2026-10-15',
  status: ChequeStatus.inWallet,
  paidAt: DateTime.utc(2026, 9, 28, 10),
);

class _FakeChequesApi extends ChequesApi {
  _FakeChequesApi() : super(Dio());

  final asked = <ChequeStatus?>[];
  final decided = <(String, ChequeStatus, String, String?)>[];

  @override
  Future<List<Cheque>> list({ChequeStatus? status}) async {
    asked.add(status);
    return [_cheque('1'), _cheque('2', kind: 'FOURNISSEUR')];
  }

  @override
  Future<Cheque> decide(
    Cheque cheque,
    ChequeStatus status, {
    required String clientMutationId,
    String? reason,
  }) async {
    decided.add((cheque.id, status, clientMutationId, reason));
    return cheque.copyWith(status: status);
  }
}

Future<_FakeChequesApi> _pump(WidgetTester tester) async {
  useScreenSize(tester, const Size(700, 1000));
  final api = _FakeChequesApi();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        chequesApiProvider.overrideWithValue(api),
        currentUserIdProvider.overrideWithValue('a'),
      ],
      child: MaterialApp(
        theme: AppTheme.mobile(dark: true),
        home: const Scaffold(body: ChequesScreen()),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return api;
}

void main() {
  testWidgets('portefeuille : reçus et émis, en portefeuille par défaut', (
    tester,
  ) async {
    final api = await _pump(tester);
    expect(api.asked, [ChequeStatus.inWallet]);
    expect(
      find.text('Reçu de Électricité Benali · ${formatDA(40000)}'),
      findsOneWidget,
    );
    expect(find.text('Émis à Sonelec · ${formatDA(40000)}'), findsOneWidget);
    expect(find.textContaining('échéance 15/10/2026'), findsNWidgets(2));
  });

  testWidgets('rejet : motif transmis, message « remis sur la dette »', (
    tester,
  ) async {
    final api = await _pump(tester);
    await tester.tap(find.textContaining('Électricité Benali'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rejeté par la banque (la dette revient)'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Provision insuffisante');
    await tester.tap(find.text('Déclarer rejeté'));
    await tester.pumpAndSettle();

    final (id, status, key, reason) = api.decided.single;
    expect(
      (id, status, reason),
      ('1', ChequeStatus.rejected, 'Provision insuffisante'),
    );
    expect(key, isNotEmpty);
    expect(find.textContaining('remis sur la dette'), findsOneWidget);
  });

  test('menu « Chèques » : ADMIN avec les deux droits de paiement', () {
    bool offered(List<String> roles, List<String> permissions) =>
        destinationsFor(
          authUser(roles: roles, permissions: permissions),
        ).any((d) => d.label == 'Chèques');
    const both = ['customer.payment.create', 'supplier.payment.create'];
    expect(offered(const ['ADMIN'], both), isTrue);
    expect(
      offered(const ['ADMIN'], const ['customer.payment.create']),
      isFalse,
    );
    expect(offered(const ['VENDEUR'], both), isFalse);
  });
}
