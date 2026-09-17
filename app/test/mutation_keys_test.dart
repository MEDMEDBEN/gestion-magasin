import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gestion_magasin/core/error/api_exception.dart';
import 'package:gestion_magasin/core/error/error_codes.dart';
import 'package:gestion_magasin/core/mutation_keys.dart';
import 'package:gestion_magasin/core/providers.dart';

/// `runMoneyMutation` a besoin d'un `Ref` : on passe par un provider de test.
final _runner = Provider(
  (ref) =>
      (String intent, Future<String> Function(String key) call) =>
          runMoneyMutation(ref, intent, call),
);

void main() {
  late ProviderContainer container;
  setUp(() {
    container = ProviderContainer(
      overrides: [currentUserIdProvider.overrideWithValue('u1')],
    );
  });
  tearDown(() => container.dispose());

  Future<String?> attempt(String intent, {ApiException? failWith}) async {
    String? used;
    try {
      await container.read(_runner)(intent, (key) async {
        used = key;
        if (failWith != null) throw failWith;
        return key;
      });
    } on ApiException {
      // attendu pour les cas d'échec
    }
    return used;
  }

  test('panne réseau : la clé est GARDÉE pour le prochain essai', () async {
    final first = await attempt(
      'pay:c1',
      failWith: const ApiException(statusCode: 0, message: 'hors ligne'),
    );
    final second = await attempt('pay:c1');
    expect(second, first);
  });

  test('succès : l’opération suivante reçoit une NOUVELLE clé', () async {
    final first = await attempt('pay:c1');
    final second = await attempt('pay:c1');
    expect(second, isNot(first));
  });

  test('refus métier (rien d’appliqué) : clé gardée', () async {
    final first = await attempt(
      'pay:c1',
      failWith: const ApiException(
        statusCode: 422,
        message: 'Caisse fermée',
        code: 'CASH_SESSION_REQUIRED',
      ),
    );
    expect(await attempt('pay:c1'), first);
  });

  test('clé déjà utilisée par une autre opération : libérée', () async {
    final first = await attempt(
      'pay:c1',
      failWith: const ApiException(
        statusCode: 409,
        message: 'déjà enregistré',
        code: ErrorCodes.paymentAlreadyRecorded,
      ),
    );
    expect(await attempt('pay:c1'), isNot(first));
  });

  test('intentions distinctes : clés distinctes', () async {
    final a = await attempt(
      'pay:c1',
      failWith: const ApiException(statusCode: 0, message: 'x'),
    );
    final b = await attempt(
      'pay:c2',
      failWith: const ApiException(statusCode: 0, message: 'x'),
    );
    expect(a, isNot(b));
  });
}
