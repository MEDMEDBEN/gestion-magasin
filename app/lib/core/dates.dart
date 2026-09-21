/// Formats de date AMPÈRE (`docs/design-system.md` §3.3) : `JJ/MM/AAAA`,
/// horodatage `JJ/MM/AAAA HH:MM`. Transport et stockage en UTC ; la conversion
/// au fuseau local se fait ICI, à l'affichage uniquement (CONVENTIONS.md).
String _two(int value) => value.toString().padLeft(2, '0');

String formatDate(DateTime value) {
  final local = value.toLocal();
  return '${_two(local.day)}/${_two(local.month)}/${local.year}';
}

String formatDateTime(DateTime value) {
  final local = value.toLocal();
  return '${formatDate(local)} ${_two(local.hour)}:${_two(local.minute)}';
}

/// Jour civil `AAAA-MM-JJ` (échéance saisie au calendrier, sans heure) — le
/// format que le serveur attend pour une échéance ou un jour planifié.
String isoDay(DateTime day) =>
    '${day.year.toString().padLeft(4, '0')}-${_two(day.month)}-${_two(day.day)}';

/// `AAAA-MM-JJ` reçu du serveur → `JJ/MM/AAAA`, SANS passer par un `DateTime`
/// (un jour civil n'a pas de fuseau : le convertir le ferait glisser).
String formatIsoDay(String day) {
  final parts = day.split('-');
  return parts.length == 3 ? '${parts[2]}/${parts[1]}/${parts[0]}' : day;
}
