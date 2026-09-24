import 'package:freezed_annotation/freezed_annotation.dart';

import '../../../data/models/page_meta.dart';

part 'notification_models.freezed.dart';
part 'notification_models.g.dart';

/// Nature de l'alerte (spec §18). Le libellé sert d'intitulé de regroupement ;
/// le titre, lui, vient du serveur et nomme le document concerné.
enum NotificationKind {
  @JsonValue('STOCK_FAIBLE')
  lowStock('Stock faible'),
  @JsonValue('RUPTURE')
  outOfStock('Rupture'),
  @JsonValue('NOUVELLE_DEMANDE_DEPOT')
  transferRequested('Demande au dépôt'),
  @JsonValue('DEMANDE_PRETE')
  transferReady('Demande prête'),
  @JsonValue('TRANSFERT')
  transfer('Transfert'),
  @JsonValue('TRANSFERT_RECU')
  transferReceived('Transfert reçu'),
  @JsonValue('COMMANDE_CONFIRMEE')
  orderConfirmed('Commande confirmée'),
  @JsonValue('RECEPTION')
  reception('Réception'),
  @JsonValue('RECEPTION_PARTIELLE')
  partialReception('Réception partielle'),
  @JsonValue('RETARD_FOURNISSEUR')
  supplierLate('Retard fournisseur'),
  @JsonValue('ECHEANCE_CLIENT')
  customerDue('Échéance client'),
  @JsonValue('DETTE_CLIENT_RETARD')
  customerOverdue('Dette client en retard'),
  @JsonValue('DETTE_FOURNISSEUR')
  supplierDebt('Dette fournisseur'),
  @JsonValue('INVENTAIRE_A_FAIRE')
  inventoryTodo('Inventaire à faire'),
  @JsonValue('ECART_DETECTE')
  discrepancy('Écart détecté'),
  @JsonValue('TACHE_DU_JOUR')
  taskToday('Tâche du jour'),
  @JsonValue('TACHE_EN_RETARD')
  taskLate('Tâche en retard'),
  @JsonValue('MESSAGE')
  message('Message'),

  /// Valeur inconnue de CETTE version de l'app : un serveur plus récent a
  /// ajouté un type. L'alerte s'affiche quand même — sans ce repli, une seule
  /// valeur nouvelle faisait échouer le décodage de TOUTE la boîte, badge
  /// compris (régression constatée en revue P1 n°17).
  unknown('Notification');

  const NotificationKind(this.label);
  final String label;
}

/// Opération visée — c'est ce lien qui rend l'alerte actionnable.
enum NotificationTarget {
  @JsonValue('SALE')
  sale,
  @JsonValue('RECEPTION')
  reception,
  @JsonValue('TRANSFER')
  transfer,
  @JsonValue('INVENTORY')
  inventory,
  @JsonValue('PURCHASE_ORDER')
  purchaseOrder,
  @JsonValue('QUOTE')
  quote,
  @JsonValue('CUSTOMER_PAYMENT')
  customerPayment,
  @JsonValue('SUPPLIER_PAYMENT')
  supplierPayment,
  @JsonValue('CASH_SESSION')
  cashSession,
  @JsonValue('PRODUCT')
  product,
  @JsonValue('CONVERSATION')
  conversation,
  @JsonValue('MANUAL')
  manual,

  /// Opération inconnue de cette version : l'alerte reste lisible, elle
  /// n'ouvre simplement aucun écran.
  unknown,
}

enum NotificationPriority {
  @JsonValue('BASSE')
  low,
  @JsonValue('NORMALE')
  normal,
  @JsonValue('HAUTE')
  high,
  @JsonValue('URGENTE')
  urgent,
}

@freezed
abstract class AppNotification with _$AppNotification {
  const factory AppNotification({
    required String id,
    @JsonKey(unknownEnumValue: NotificationKind.unknown)
    required NotificationKind type,
    @JsonKey(unknownEnumValue: NotificationPriority.normal)
    required NotificationPriority priority,
    required String title,
    String? body,
    required bool isRead,
    DateTime? readAt,
    @JsonKey(unknownEnumValue: NotificationTarget.unknown)
    NotificationTarget? operationType,
    String? operationId,
    required DateTime createdAt,
  }) = _AppNotification;

  factory AppNotification.fromJson(Map<String, dynamic> json) =>
      _$AppNotificationFromJson(json);
}

/// Une page de notifications ET le nombre total de non lues : le badge ne se
/// déduit jamais de la page affichée, qui n'en montre qu'une partie.
@freezed
abstract class NotificationPage with _$NotificationPage {
  const factory NotificationPage({
    required List<AppNotification> data,
    required PageMeta meta,
    required int unread,
  }) = _NotificationPage;

  factory NotificationPage.fromJson(Map<String, dynamic> json) =>
      _$NotificationPageFromJson(json);
}
