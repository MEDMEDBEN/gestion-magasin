import 'package:decimal/decimal.dart';

/// Les quantités sont DÉCIMALES (CLAUDE.md règle 10) — certains produits se
/// vendent au mètre. Jamais de `double` : l'arithmétique flottante fait dériver
/// un stock. Le transport JSON se fait en CHAÎNE, comme le `Decimal(14,3)` Prisma.
typedef Quantity = Decimal;

/// Échelle du schéma : `Decimal(14,3)`.
const int quantityScale = 3;

/// Décode une quantité reçue du serveur (toujours une chaîne).
Quantity quantityFromJson(Object? value) => switch (value) {
  null => Decimal.zero,
  String s => Decimal.parse(s),
  int i => Decimal.fromInt(i),
  // Un nombre JSON non entier signale un producteur qui n'applique pas le
  // contrat : on le convertit sans passer par un double.
  _ => Decimal.parse(value.toString()),
};

/// Encode une quantité pour le serveur, à l'échelle exacte du schéma.
String quantityToJson(Quantity value) => value.toStringAsFixed(quantityScale);

/// Parse une saisie utilisateur (« 12,5 » ou « 12.5 »). Null si invalide.
Quantity? parseQuantity(String input) {
  final cleaned = input.replaceAll(' ', '').replaceAll(',', '.').trim();
  if (cleaned.isEmpty) return null;
  return Decimal.tryParse(cleaned);
}

/// Affichage : on retire les zéros de fin inutiles (« 12,500 » → « 12,5 »).
String formatQuantity(Quantity value) {
  var text = value.toStringAsFixed(quantityScale);
  if (text.contains('.')) {
    text = text.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
  }
  return text.replaceAll('.', ',');
}
