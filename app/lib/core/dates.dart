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
