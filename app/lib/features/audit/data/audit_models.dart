import 'dart:convert';

import 'package:freezed_annotation/freezed_annotation.dart';

import '../../../core/money.dart';
import '../../../data/models/page_meta.dart';

part 'audit_models.freezed.dart';
part 'audit_models.g.dart';

enum AuditAction {
  @JsonValue('CREATE')
  create('Création'),
  @JsonValue('UPDATE')
  update('Modification'),
  @JsonValue('CANCEL')
  cancel('Annulation'),
  @JsonValue('VALIDATE')
  validate('Validation'),
  @JsonValue('ADJUST')
  adjust('Ajustement'),
  @JsonValue('CLOSE')
  close('Clôture');

  const AuditAction(this.label);
  final String label;

  String get wire => name.toUpperCase();
}

/// Libellés des objets tracés (le serveur renvoie le nom du modèle).
const auditEntityLabels = <String, String>{
  'Product': 'Produit',
  'ProductPrice': 'Prix',
  'Category': 'Catégorie',
  'Location': 'Emplacement',
  'StockMovement': 'Mouvement de stock',
  'StockLossDeclaration': 'Perte / casse',
  'Sale': 'Vente',
  'CashSession': 'Caisse',
  'Customer': 'Client',
  'CustomerPayment': 'Règlement client',
  'Supplier': 'Fournisseur',
  'SupplierPayment': 'Paiement fournisseur',
  'PurchaseOrder': 'Commande fournisseur',
  'Reception': 'Réception',
  'Transfer': 'Transfert',
  'Inventory': 'Inventaire',
  'PlanningTask': 'Tâche',
  'User': 'Compte',
};

String auditEntityLabel(String type) => auditEntityLabels[type] ?? type;

@freezed
abstract class AuditEntry with _$AuditEntry {
  const factory AuditEntry({
    required String id,
    String? userId,
    String? userName,
    required AuditAction action,
    required String entityType,
    required String entityId,
    Map<String, dynamic>? oldValue,
    Map<String, dynamic>? newValue,
    String? ipAddress,
    required DateTime createdAt,
  }) = _AuditEntry;

  factory AuditEntry.fromJson(Map<String, dynamic> json) =>
      _$AuditEntryFromJson(json);
}

@freezed
abstract class AuditPage with _$AuditPage {
  const factory AuditPage({
    required List<AuditEntry> data,
    required PageMeta meta,
  }) = _AuditPage;

  factory AuditPage.fromJson(Map<String, dynamic> json) =>
      _$AuditPageFromJson(json);
}

/// Un champ qui a changé entre l'avant et l'après d'une entrée.
typedef AuditChange = ({String field, String before, String after});

/// Libellés des champs les plus fréquents ; les autres gardent leur nom.
const _fieldLabels = <String, String>{
  'name': 'Nom',
  'fullName': 'Nom',
  'title': 'Intitulé',
  'sku': 'Référence',
  'barcode': 'Code-barres',
  'status': 'Statut',
  'isActive': 'Actif',
  'roles': 'Rôles',
  'email': 'E-mail',
  'phone': 'Téléphone',
  'priceHt': 'Prix HT',
  'unitPriceHt': 'Prix unitaire HT',
  'totalTtc': 'Total TTC',
  'amount': 'Montant',
  'creditLimit': 'Plafond de crédit',
  'openingBalance': 'Reprise de dette',
  'assignedToId': 'Confiée à',
  'dueDate': 'Échéance',
  'reason': 'Motif',
  'result': 'Résultat',
  'operation': 'Opération',
};

/// Opérations de sécurité tracées sur un compte (codes du serveur). La
/// détection d'un vol de session est l'entrée la plus sensible du journal :
/// elle doit se lire, pas se déchiffrer.
const _operationLabels = <String, String>{
  'REFRESH_TOKEN_REUSE_DETECTED':
      'Vol de session présumé : toutes les sessions coupées',
  'PASSWORD_CHANGE': 'Mot de passe changé',
  'PASSWORD_RESET': 'Mot de passe réinitialisé par l’admin',
  'REVOKE_SESSIONS': 'Sessions révoquées',
  'LOGOUT_ALL_DEVICES': 'Déconnexion de tous les appareils',
};

/// Les montants sont tracés en CENTIMES (règle 4) : « 120000 » pour un prix
/// de 1 200,00 DA induirait l'admin en erreur. Les quantités, elles, sont
/// tracées en chaînes (« 12.500 ») et ne tombent pas ici.
/// ponytail: reconnaissance par le NOM du champ ; une liste explicite par type
/// d'objet si un jour un entier non monétaire porte un de ces mots.
/// `difference` : l'écart de caisse du rapport Z, en centimes — le chiffre le
/// plus sensible de la clôture. (Celui d'un inventaire est une QUANTITÉ, tracée
/// en chaîne : il ne passe jamais par la branche entière.)
final _moneyField = RegExp(
  r'(price|amount|total|balance|limit|float|debt|paid|difference)',
  caseSensitive: false,
);

/// Affichage d'une valeur tracée, RÉCURSIF : les lignes d'une réception ou
/// d'une commande portent leurs propres prix, qui doivent eux aussi se lire en
/// dinars (revue du 2026-09-21 — ils s'affichaient en centimes bruts).
String _display(String field, Object? value) {
  if (value == null) return '—';
  if (value is bool) return value ? 'oui' : 'non';
  if (field == 'operation' && value is String) {
    return _operationLabels[value] ?? value;
  }
  if (value is int && _moneyField.hasMatch(field)) return formatDA(value);
  if (value is List) {
    if (value.isEmpty) return '—';
    // Des LIGNES (objets) se séparent nettement ; des valeurs simples (rôles)
    // se lisent en énumération.
    final separator = value.first is Map ? ' · ' : ', ';
    return value.map((item) => _display(field, item)).join(separator);
  }
  if (value is Map) {
    return [
      for (final entry in value.entries)
        '${_fieldLabels[entry.key] ?? entry.key} ${_display('${entry.key}', entry.value)}',
    ].join(', ');
  }
  return '$value';
}

/// Ce qui a changé, champ par champ. Une CRÉATION n'a pas d'avant, une
/// ANNULATION pas d'après : on montre alors ce qui existe.
List<AuditChange> auditChanges(
  Map<String, dynamic>? before,
  Map<String, dynamic>? after,
) {
  final keys = {...?before?.keys, ...?after?.keys};
  return [
    for (final key in keys)
      if (jsonEncode(before?[key]) != jsonEncode(after?[key]))
        (
          field: _fieldLabels[key] ?? key,
          before: before == null ? '' : _display(key, before[key]),
          after: after == null ? '' : _display(key, after[key]),
        ),
  ];
}
