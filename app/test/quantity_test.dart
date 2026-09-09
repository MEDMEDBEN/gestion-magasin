import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gestion_magasin/core/quantity.dart';

/// Les quantités sont décimales (CLAUDE.md règle 10) et transitent en CHAÎNE.
/// Un double ferait dériver le stock : ces tests l'interdisent.
void main() {
  group('quantityFromJson', () {
    test('décode la chaîne envoyée par le serveur', () {
      expect(quantityFromJson('12.500'), Decimal.parse('12.5'));
    });

    test('traite une absence comme zéro', () {
      expect(quantityFromJson(null), Decimal.zero);
    });

    test('accepte un entier JSON', () {
      expect(quantityFromJson(20), Decimal.fromInt(20));
    });
  });

  group('quantityToJson', () {
    test('encode à l’échelle exacte du schéma Decimal(14,3)', () {
      expect(quantityToJson(Decimal.parse('12.5')), '12.500');
      expect(quantityToJson(Decimal.fromInt(3)), '3.000');
    });
  });

  test('aller-retour serveur sans perte', () {
    for (final raw in ['0.001', '12.500', '1000.250', '99999.999']) {
      expect(quantityToJson(quantityFromJson(raw)), raw);
    }
  });

  group('parseQuantity', () {
    test('accepte la virgule française', () {
      expect(parseQuantity('12,5'), Decimal.parse('12.5'));
    });

    test('refuse une saisie invalide', () {
      expect(parseQuantity('abc'), isNull);
      expect(parseQuantity(''), isNull);
    });
  });

  group('formatQuantity', () {
    test('retire les zéros de fin inutiles', () {
      expect(formatQuantity(Decimal.parse('12.500')), '12,5');
      expect(formatQuantity(Decimal.fromInt(20)), '20');
    });

    test('conserve les décimales significatives', () {
      expect(formatQuantity(Decimal.parse('0.125')), '0,125');
    });
  });

  test('l’arithmétique décimale reste exacte (pas de dérive flottante)', () {
    // 0.1 + 0.2 == 0.3 est FAUX en double ; ce doit être vrai ici.
    final sum = Decimal.parse('0.1') + Decimal.parse('0.2');
    expect(sum, Decimal.parse('0.3'));
  });
}
