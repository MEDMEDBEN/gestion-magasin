import 'package:flutter_test/flutter_test.dart';
import 'package:gestion_magasin/core/money.dart';

/// Le séparateur attendu est celui du code : on ne réécrit jamais une espace
/// littérale dans un test, sous peine de comparer deux caractères invisibles.
final sep = thousandsSeparator;

/// L'argent est un entier de centimes (CLAUDE.md règle 4) : ces tests
/// verrouillent l'aller-retour saisie → centimes → affichage.
void main() {
  group('formatDA', () {
    test('formate des centimes en dinars avec séparateur de milliers', () {
      expect(formatDA(145000), '1${sep}450,00 DA');
      expect(formatDA(100), '1,00 DA');
      expect(formatDA(0), '0,00 DA');
    });

    test('conserve les centimes non nuls', () {
      expect(formatDA(145050), '1${sep}450,50 DA');
      expect(formatDA(5), '0,05 DA');
    });

    test('gère les montants négatifs (avoir, écart de caisse)', () {
      expect(formatDA(-2500), '-25,00 DA');
    });

    test('groupe correctement les grands montants', () {
      expect(formatDA(50000000), '500${sep}000,00 DA');
      expect(formatDA(123456789), '1${sep}234${sep}567,89 DA');
    });

    test('peut omettre le symbole', () {
      expect(formatDA(145000, withSymbol: false), '1${sep}450,00');
    });
  });

  group('parseDA', () {
    test('accepte un entier de dinars', () {
      expect(parseDA('1450'), 145000);
    });

    test('accepte la virgule ET le point comme séparateur décimal', () {
      expect(parseDA('1450,50'), 145050);
      expect(parseDA('1450.50'), 145050);
    });

    test('complète une décimale unique', () {
      expect(parseDA('12,5'), 1250);
    });

    test('ignore les espaces de saisie', () {
      expect(parseDA('1 450,50'), 145050);
    });

    test('refuse une saisie invalide plutôt que de deviner', () {
      expect(parseDA('abc'), isNull);
      expect(parseDA('12,345'), isNull); // plus de 2 décimales
      expect(parseDA('1.2.3'), isNull);
      expect(parseDA(''), isNull);
    });

    test('aller-retour sans perte de précision', () {
      for (final centimes in [0, 1, 99, 100, 145050, 123456789]) {
        expect(parseDA(formatDA(centimes, withSymbol: false)), centimes);
      }
    });
  });
}
