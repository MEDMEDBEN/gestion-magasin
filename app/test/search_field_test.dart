import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gestion_magasin/ui/widgets/page_kit.dart';

/// Bug terrain du 2026-10-29 : « led » tapé sur téléphone cherchait « del ».
/// Le navigateur insère chaque lettre au curseur ; un curseur perdu (sélection
/// invalide) le renvoyait au début.
void main() {
  test(
    'curseur perdu : il revient en fin, les lettres restent dans l’ordre',
    () {
      final field = SearchField();
      var text = '';
      for (final char in ['l', 'e', 'd']) {
        // Ce que fait le navigateur : insérer au curseur (début s'il est perdu).
        final at = field.selection.isValid ? field.selection.baseOffset : 0;
        text = text.replaceRange(at, at, char);
        // … puis une reconstruction perd la position du curseur.
        field.value = TextEditingValue(text: text);
        text = field.text;
      }
      expect(field.text, 'led');
      expect(field.selection, const TextSelection.collapsed(offset: 3));
    },
  );
}
