/// Confrère (décision MEDMEDBEN 2026-10-08) : un autre commerçant, à la fois
/// client et fournisseur. Montants en centimes, calculés par le serveur.
class Confrere {
  const Confrere({
    required this.id,
    required this.supplierId,
    required this.name,
    this.phone,
    required this.theyOwe,
    required this.weOwe,
    required this.net,
  });

  /// Identifiant CLIENT (ventes, règlements reçus).
  final String id;

  /// Sa fiche fournisseur (achats, paiements versés par l'admin).
  final String supplierId;
  final String name;
  final String? phone;

  /// Ce qu'il me doit.
  final int theyOwe;

  /// Ce que je lui dois.
  final int weOwe;

  /// `theyOwe − weOwe` : positif, il me doit.
  final int net;

  factory Confrere.fromJson(Map<String, dynamic> json) => Confrere(
    id: json['id'] as String,
    supplierId: json['supplierId'] as String,
    name: json['name'] as String,
    phone: json['phone'] as String?,
    theyOwe: json['theyOwe'] as int,
    weOwe: json['weOwe'] as int,
    net: json['net'] as int,
  );
}
