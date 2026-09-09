/// L'argent est un ENTIER de centimes de DA, partout (CLAUDE.md règle 4).
/// Aucun `double` ne doit jamais porter un montant, même transitoirement.
typedef Money = int;

/// Séparateur de milliers : espace FINE INSÉCABLE (U+202F), typographie
/// française correcte. Construit depuis son code point plutôt qu'écrit en
/// littéral : une espace invisible dans le source est un piège — deux variantes
/// d'espace sont indiscernables à l'œil et produisent des tests faux-négatifs.
final String thousandsSeparator = String.fromCharCode(0x202F);

/// Unique utilitaire de formatage monétaire du projet (CONVENTIONS.md).
/// N'utiliser AUCUN autre formatage ailleurs.
String formatDA(Money centimes, {bool withSymbol = true}) {
  final isNegative = centimes < 0;
  final absolute = centimes.abs();
  final dinars = absolute ~/ 100;
  final cents = absolute % 100;

  final grouped = _groupThousands(dinars);
  final decimals = cents.toString().padLeft(2, '0');
  final sign = isNegative ? '-' : '';
  final suffix = withSymbol ? ' DA' : '';

  return '$sign$grouped,$decimals$suffix';
}

String _groupThousands(int value) {
  final digits = value.toString();
  final buffer = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) {
      buffer.write(thousandsSeparator);
    }
    buffer.write(digits[i]);
  }
  return buffer.toString();
}

/// Convertit une saisie utilisateur en centimes, sans jamais passer par un double.
/// Accepte « 1450 », « 1450,50 », « 1450.5 ». Renvoie null si la saisie est invalide.
Money? parseDA(String input) {
  // On retire tout ce qui n'est ni chiffre, ni signe, ni séparateur décimal :
  // cela couvre d'un coup toutes les variantes d'espace (dont l'espace fine
  // insécable produite par formatDA) et un éventuel symbole « DA » collé.
  final cleaned = input.replaceAll(RegExp(r'[^\d,.\-]'), '').replaceAll(',', '.');
  if (cleaned.isEmpty) return null;

  final parts = cleaned.split('.');
  if (parts.length > 2) return null;

  final wholePart = parts[0].isEmpty ? '0' : parts[0];
  if (!RegExp(r'^-?\d+$').hasMatch(wholePart)) return null;

  var centimes = int.parse(wholePart) * 100;

  if (parts.length == 2) {
    final fraction = parts[1];
    if (!RegExp(r'^\d{1,2}$').hasMatch(fraction)) return null;
    final cents = int.parse(fraction.padRight(2, '0'));
    centimes += wholePart.startsWith('-') ? -cents : cents;
  }

  return centimes;
}
