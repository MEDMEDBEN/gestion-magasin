import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gestion_magasin/core/providers.dart';
import 'package:gestion_magasin/data/local/app_database.dart';
import 'package:gestion_magasin/features/audit/data/audit_api.dart';
import 'package:gestion_magasin/features/audit/data/audit_models.dart';
import 'package:gestion_magasin/features/auth/application/auth_controller.dart';
import 'package:gestion_magasin/features/auth/data/auth_models.dart';
import 'package:gestion_magasin/features/auth/presentation/change_password_screen.dart';
import 'package:gestion_magasin/features/auth/presentation/login_screen.dart';
import 'package:gestion_magasin/features/catalog/application/catalog_controller.dart';
import 'package:gestion_magasin/features/catalog/data/catalog_models.dart';
import 'package:gestion_magasin/features/stock/application/stock_controller.dart';
import 'package:gestion_magasin/features/stock/data/stock_api.dart';
import 'package:gestion_magasin/features/stock/data/stock_models.dart';
import 'package:decimal/decimal.dart';
import 'package:dio/dio.dart';
import 'package:gestion_magasin/data/models/page_meta.dart';
import 'package:gestion_magasin/features/sales/data/sales_api.dart';
import 'package:gestion_magasin/features/sales/data/sales_models.dart';
import 'package:gestion_magasin/features/inventory/data/inventory_api.dart';
import 'package:gestion_magasin/features/inventory/data/inventory_models.dart';
import 'package:gestion_magasin/features/planning/data/planning_api.dart';
import 'package:gestion_magasin/features/planning/data/planning_models.dart';
import 'package:gestion_magasin/features/purchases/data/purchases_api.dart';
import 'package:gestion_magasin/features/purchases/data/purchases_models.dart';
import 'package:gestion_magasin/features/receptions/data/receptions_api.dart';
import 'package:gestion_magasin/features/receptions/data/receptions_models.dart';
import 'package:gestion_magasin/features/suppliers/data/suppliers_api.dart';
import 'package:gestion_magasin/features/transfers/data/transfers_api.dart';
import 'package:gestion_magasin/features/transfers/data/transfers_models.dart';
import 'package:gestion_magasin/features/suppliers/data/suppliers_models.dart';
import 'package:gestion_magasin/features/users/data/users_api.dart';
import 'package:gestion_magasin/features/scan/presentation/scanned_product_sheet.dart';
import 'package:gestion_magasin/ui/adaptive_shell.dart';
import 'package:gestion_magasin/ui/breakpoints.dart';
import 'package:gestion_magasin/ui/theme/app_theme.dart';

import '../support/catalog_fakes.dart';
import '../support/fakes.dart';

/// OUTIL (opt-in) de vérification visuelle : rend les vrais écrans avec les
/// vraies polices (Archivo, Lucide) et des données fictives, en PNG, pour
/// relire le design AMPÈRE sur toutes les tailles sans appareil sous la main.
///
///   flutter test test/tools/screen_captures_test.dart --dart-define=CAPTURE_OUT=/chemin/dossier
///
/// Sans `CAPTURE_OUT`, ces tests sont IGNORÉS : `flutter test` ne produit rien.
const out = String.fromEnvironment('CAPTURE_OUT');

class _SignedIn extends AuthController {
  _SignedIn(this.user);
  final AuthUser user;
  @override
  Future<AuthState> build() async => AuthSignedIn(user);
}

class _SignedOut extends AuthController {
  @override
  Future<AuthState> build() async => const AuthSignedOut();
}

final _users = [
  managedUser(
    id: 'me',
    fullName: 'Radhi Badache',
    email: 'admin@magasin.dz',
    roles: const ['ADMIN'],
    lastLoginAt: DateTime(2026, 9, 11, 9, 2),
  ),
  managedUser(
    id: 'u2',
    fullName: 'Amine Benali',
    email: 'amine@magasin.dz',
    roles: const ['VENDEUR'],
    lastLoginAt: DateTime(2026, 9, 10, 17, 45),
  ),
  managedUser(
    id: 'u3',
    fullName: 'Karim Saidi',
    email: null,
    phone: '+213555123456',
    roles: const ['MAGASINIER', 'VENDEUR'],
    lastLoginAt: DateTime(2026, 9, 11, 7, 58),
  ),
  managedUser(
    id: 'u4',
    fullName: 'Nadia Kaci',
    email: 'nadia@magasin.dz',
    roles: const ['VENDEUR'],
    mustChangePassword: true,
  ),
  managedUser(
    id: 'u5',
    fullName: 'Yacine Ouali',
    email: 'yacine@magasin.dz',
    roles: const ['MAGASINIER'],
    isActive: false,
    lastLoginAt: DateTime(2026, 8, 28, 16, 10),
  ),
];

class _IdleSync extends CatalogSyncController {
  @override
  Future<void> build() async {}
}

/// Droits de l'ADMIN — côté serveur, `ROLE_PERMISSIONS[ADMIN]` vaut TOUTES les
/// permissions : cette liste les reprend intégralement, y compris celles des
/// features encore à livrer, pour qu'elle ne redevienne pas incomplète en
/// silence (un admin de capture amputé ne voit pas les écrans livrés).
const _adminPermissions = [
  'user.manage',
  'settings.manage',
  'audit.read',
  'product.read',
  'product.write',
  'product.disable',
  'price.manage',
  'price.read',
  'cost.read',
  'location.manage',
  'stock.read.store',
  'stock.read.warehouse',
  'stock.adjust',
  'stock.adjust.validate',
  'stock.loss',
  'sale.create',
  'sale.discount',
  'sale.credit',
  'sale.cancel',
  'invoice.issue',
  'cash.session.manage',
  'cash.report.read',
  'customer.read',
  'customer.write',
  'customer.payment.create',
  'supplier.read',
  'supplier.write',
  'supplier.payment.create',
  'purchase.create',
  'purchase.confirm',
  'reception.create',
  'transfer.request',
  'transfer.prepare',
  'transfer.receive',
  'transfer.cancel',
  'inventory.create',
  'inventory.validate',
  'planning.manage',
  'planning.task.read',
];

final _categories = [
  category(id: 'cab', name: 'Câbles'),
  category(id: 'cab-s', name: 'Câbles souples', parentId: 'cab'),
  category(id: 'prot', name: 'Protection'),
  category(id: 'ecl', name: 'Éclairage'),
];

final _products = [
  product(
    id: 'p1',
    name: 'Câble souple H07RN-F 3G2,5',
    sku: 'CAB-3G25',
    barcode: '3245060123458',
    brand: 'Nexans',
    categoryId: 'cab-s',
    unit: ProductUnit.metre,
    minThreshold: '100',
  ),
  product(
    id: 'p2',
    name: 'Disjoncteur DX³ 16A courbe C',
    sku: 'DIS-16C',
    barcode: '3245064074152',
    brand: 'Legrand',
    categoryId: 'prot',
    minThreshold: '10',
  ),
  product(
    id: 'p3',
    name: 'Interrupteur différentiel 40A 30mA',
    sku: 'ID-40-30',
    barcode: '2000000000015',
    brand: 'Schneider',
    categoryId: 'prot',
    minThreshold: '4',
  ),
  product(
    id: 'p4',
    name: 'Réglette LED 36W 120 cm',
    sku: 'LED-R36',
    barcode: '2000000000022',
    categoryId: 'ecl',
    minThreshold: '12.5',
  ),
  product(
    id: 'p5',
    name: 'Gaine ICTA Ø20 (couronne 100 m)',
    sku: 'GAI-20',
    barcode: '2000000000039',
    unit: ProductUnit.rouleau,
    minThreshold: '3',
  ),
];

StorageLocation _bin(String id, String code, String name) => StorageLocation(
  id: id,
  code: code,
  name: name,
  type: 'EMPLACEMENT',
  parentId: 'depot',
  isActive: true,
  updatedAt: DateTime.utc(2026, 9, 14),
);

final _locations = [
  StorageLocation(
    id: 'magasin',
    code: 'MAGASIN',
    name: 'Magasin',
    type: 'MAGASIN',
    isActive: true,
    updatedAt: DateTime.utc(2026, 9, 14),
  ),
  StorageLocation(
    id: 'depot',
    code: 'DEPOT',
    name: 'Dépôt',
    type: 'DEPOT',
    isActive: true,
    updatedAt: DateTime.utc(2026, 9, 14),
  ),
  _bin('l1', 'A-01-01-01', 'Zone A · Rayon 01 · Étagère 01 · Position 01'),
  _bin('l2', 'A-01-02-03', 'Zone A · Rayon 01 · Étagère 02 · Position 03'),
  _bin('l3', 'B-04-01-02', 'Zone B · Rayon 04 · Étagère 01 · Position 02'),
];

StockLevel _stock(String productId, String locationId, String quantity) =>
    StockLevel(
      productId: productId,
      locationId: locationId,
      quantity: Decimal.parse(quantity),
      reservedQuantity: Decimal.zero,
      inTransitQuantity: Decimal.zero,
      availableQuantity: Decimal.parse(quantity),
    );

final _stockByProduct = {
  'p1': ProductStock([
    _stock('p1', 'magasin', '120'),
    _stock('p1', 'depot', '480'),
  ]),
  'p2': ProductStock([
    _stock('p2', 'magasin', '4'),
    _stock('p2', 'depot', '2'),
  ]),
  'p3': ProductStock([
    _stock('p3', 'magasin', '6'),
    _stock('p3', 'depot', '12'),
  ]),
  'p4': ProductStock([
    _stock('p4', 'magasin', '9'),
    _stock('p4', 'depot', '40'),
  ]),
  'p5': ProductStock([_stock('p5', 'depot', '7')]),
};

class _CaptureStockApi extends StockApi {
  _CaptureStockApi() : super(Dio());

  @override
  Future<StockLossPage> losses({
    StockLossStatus? status,
    int limit = 200,
  }) async => StockLossPage(
    data: [
      StockLoss(
        id: 'l1',
        productId: 'p4',
        locationId: 'depot',
        quantity: Decimal.parse('2'),
        comment: 'Deux réglettes cassées au déchargement',
        status: StockLossStatus.pending,
        declaredById: 'm',
        createdAt: DateTime(2026, 9, 14, 8, 40),
      ),
      StockLoss(
        id: 'l2',
        productId: 'p1',
        locationId: 'magasin',
        quantity: Decimal.parse('3.5'),
        comment: 'Chute de coupe inutilisable',
        status: StockLossStatus.pending,
        declaredById: 'm',
        createdAt: DateTime(2026, 9, 14, 10, 5),
      ),
    ],
    meta: const PageMeta(page: 1, limit: 200, total: 2),
  );
}

class _CaptureSuppliersApi extends SuppliersApi {
  _CaptureSuppliersApi() : super(Dio());

  @override
  Future<SupplierPage> list({
    String? query,
    bool includeInactive = false,
  }) async => const SupplierPage(
    data: [
      Supplier(
        id: 'f1',
        name: 'Sonelgaz Matériel',
        phone: '021 55 44 33',
        contactName: 'M. Rahmani',
        openingBalance: 1850000,
        paidAmount: 600000,
        balanceDue: 1250000,
        isActive: true,
      ),
      Supplier(
        id: 'f2',
        name: 'Câbles du Sud',
        phone: '0661 20 30 40',
        openingBalance: 900000,
        paidAmount: 900000,
        balanceDue: 0,
        isActive: true,
      ),
      Supplier(
        id: 'f3',
        name: 'Legrand Algérie',
        contactName: 'Mme Amrani',
        openingBalance: 430000,
        paidAmount: 0,
        balanceDue: 430000,
        isActive: true,
      ),
    ],
    meta: PageMeta(page: 1, limit: 200, total: 3),
  );
}

PurchaseOrder _po(
  String n,
  String supplier,
  PurchaseStatus status,
  int ttc,
  int lines, {
  int received = 0,
}) => PurchaseOrder(
  id: 'po$n',
  number: 'BC-2026-0000$n',
  supplierId: supplier,
  status: status,
  orderDate: DateTime(2026, 9, 10 + int.parse(n)),
  totalHt: (ttc / 1.19).round(),
  totalTax: ttc - (ttc / 1.19).round(),
  totalTtc: ttc,
  updatedAt: DateTime(2026, 9, 16),
  lines: [
    for (var i = 0; i < lines; i++)
      PurchaseLine(
        id: 'po$n-$i',
        productId: 'p${i + 1}',
        orderedQuantity: Decimal.fromInt(10),
        receivedQuantity: Decimal.fromInt(received),
        remainingQuantity: Decimal.fromInt(10 - received),
        unitPriceHt: 1000,
        taxRate: '19.00',
        lineTotalHt: 10000,
        lineTotalTtc: 11900,
      ),
  ],
);

class _CapturePurchasesApi extends PurchasesApi {
  _CapturePurchasesApi() : super(Dio());

  @override
  Future<PurchaseOrderPage> list({int limit = 200}) async => PurchaseOrderPage(
    data: [
      _po('4', 'f1', PurchaseStatus.draft, 4284000, 3),
      _po('3', 'f3', PurchaseStatus.ordered, 1428000, 2),
      _po(
        '5',
        'f1',
        PurchaseStatus.partiallyReceived,
        11900000,
        2,
        received: 4,
      ),
      _po('2', 'f1', PurchaseStatus.confirmed, 21420000, 5),
      _po('1', 'f2', PurchaseStatus.cancelled, 595000, 1),
    ],
    meta: const PageMeta(page: 1, limit: 200, total: 5),
  );
}

class _CaptureReceptionsApi extends ReceptionsApi {
  _CaptureReceptionsApi() : super(Dio());

  @override
  Future<List<Reception>> list({
    String? purchaseOrderId,
    int limit = 50,
  }) async => [
    Reception(
      id: 'r1',
      number: 'BR-2026-00001',
      purchaseOrderId: 'po5',
      supplierId: 'f1',
      locationId: 'depot',
      receivedAt: DateTime(2026, 9, 18, 10, 30),
      totalTtc: 4284000,
      lines: [
        ReceptionLine(
          id: 'rl1',
          productId: 'p1',
          purchaseLineId: 'po5-0',
          receivedQuantity: Decimal.fromInt(6),
          unitPriceHt: 1000,
          lineTotalHt: 6000,
          lineTotalTtc: 7140,
        ),
      ],
    ),
  ];
}

/// Le tableau des transferts à toutes les étapes du flux.
class _CaptureTransfersApi extends TransfersApi {
  _CaptureTransfersApi() : super(Dio());

  static Transfer _trf(
    String n,
    TransferStatus status,
    TransferPriority priority, {
    String asked = '20',
    String prepared = '0',
    String shipped = '0',
    String received = '0',
    String productId = 'p1',
  }) => Transfer(
    id: 't$n',
    number: 'TRF-2026-0000$n',
    status: status,
    priority: priority,
    fromLocationId: 'depot',
    toLocationId: 'magasin',
    requestedById: 'me',
    requestedAt: DateTime(2026, 9, 21, 9, 15),
    updatedAt: DateTime(2026, 9, 21, 9, 15),
    comment: 'Rayon vide, deux clients qui attendent',
    lines: [
      TransferLine(
        id: 'tl$n',
        productId: productId,
        requestedQuantity: Decimal.parse(asked),
        preparedQuantity: Decimal.parse(prepared),
        shippedQuantity: Decimal.parse(shipped),
        receivedQuantity: Decimal.parse(received),
      ),
    ],
  );

  @override
  Future<TransferPage> list({String? status, int limit = 200}) async =>
      TransferPage(
        data: [
          _trf('4', TransferStatus.requested, TransferPriority.urgent),
          _trf(
            '3',
            TransferStatus.prepared,
            TransferPriority.normal,
            asked: '40',
            prepared: '36',
            productId: 'p2',
          ),
          _trf(
            '2',
            TransferStatus.inTransit,
            TransferPriority.high,
            asked: '12',
            prepared: '12',
            shipped: '12',
            productId: 'p3',
          ),
          _trf(
            '1',
            TransferStatus.received,
            TransferPriority.normal,
            asked: '25',
            prepared: '25',
            shipped: '25',
            received: '23',
            productId: 'p4',
          ),
        ],
        meta: const PageMeta(page: 1, limit: 200, total: 4),
      );
}

/// Inventaires à toutes les étapes : comptage en cours, écarts à valider, clos.
class _CaptureInventoryApi extends InventoryApi {
  _CaptureInventoryApi() : super(Dio());

  static InventoryLine _line(
    String productId,
    String theoretical, {
    String? counted,
    String difference = '0',
  }) => InventoryLine(
    id: 'il-$productId',
    productId: productId,
    theoreticalQuantity: Decimal.parse(theoretical),
    countedQuantity: counted == null ? null : Decimal.parse(counted),
    difference: Decimal.parse(difference),
    state: difference == '0'
        ? InventoryLineState.matching
        : InventoryLineState.gap,
  );

  @override
  Future<InventoryPage> list({String? status, int limit = 100}) async =>
      InventoryPage(
        data: [
          Inventory(
            id: 'inv3',
            number: 'INV-2026-00003',
            status: InventoryStatus.inProgress,
            type: InventoryType.cycle,
            locationId: 'depot',
            zone: 'Zone A — câbles',
            createdById: 'me',
            startedAt: DateTime(2026, 9, 21, 8, 30),
            updatedAt: DateTime(2026, 9, 21, 8, 30),
            lines: [
              _line('p1', '120'),
              _line('p2', '45', counted: '45'),
              _line('p3', '8'),
            ],
          ),
          Inventory(
            id: 'inv2',
            number: 'INV-2026-00002',
            status: InventoryStatus.completed,
            type: InventoryType.cycle,
            locationId: 'depot',
            zone: 'Zone B — disjoncteurs',
            createdById: 'me',
            startedAt: DateTime(2026, 9, 20, 9, 0),
            completedAt: DateTime(2026, 9, 20, 11, 15),
            updatedAt: DateTime(2026, 9, 20, 11, 15),
            lines: [
              _line('p1', '120', counted: '117.5', difference: '-2.5'),
              _line('p4', '30', counted: '30'),
            ],
          ),
          Inventory(
            id: 'inv1',
            number: 'INV-2026-00001',
            status: InventoryStatus.completed,
            type: InventoryType.full,
            locationId: 'magasin',
            createdById: 'me',
            validatedById: 'me',
            startedAt: DateTime(2026, 9, 18, 7, 45),
            completedAt: DateTime(2026, 9, 18, 12, 0),
            validatedAt: DateTime(2026, 9, 18, 14, 20),
            updatedAt: DateTime(2026, 9, 18, 14, 20),
            lines: [_line('p2', '45', counted: '45')],
          ),
        ],
        meta: const PageMeta(page: 1, limit: 100, total: 3),
      );
}

/// Une semaine de planning : du retard, du travail en cours, du travail fait.
class _CapturePlanningApi extends PlanningApi {
  _CapturePlanningApi() : super(Dio());

  static PlanningTask _t(
    String id,
    String title,
    PlanningTaskType type,
    PlanningTaskStatus status,
    String assignedToId,
    String due, {
    bool late = false,
    String? zone,
    String? result,
  }) => PlanningTask(
    id: id,
    title: title,
    type: type,
    status: status,
    isLate: late,
    assignedToId: assignedToId,
    createdById: 'me',
    zone: zone,
    scheduledFor: '2026-09-21',
    dueDate: due,
    result: result,
    completedAt: status == PlanningTaskStatus.done
        ? DateTime(2026, 9, 21, 11, 40)
        : null,
    updatedAt: DateTime(2026, 9, 21, 8, 0),
  );

  @override
  Future<PlanningTaskPage> list({
    String? assignedToId,
    PlanningView view = PlanningView.open,
    int limit = 200,
  }) async {
    // Comme le serveur : chaque vue ne montre que ce qui lui appartient.
    final data = [
      for (final t in _all)
        if (switch (view) {
          PlanningView.open => t.status != PlanningTaskStatus.done,
          PlanningView.late => t.isLate,
          PlanningView.done => t.status == PlanningTaskStatus.done,
        })
          t,
    ];
    return PlanningTaskPage(
      data: data,
      meta: PageMeta(page: 1, limit: 200, total: data.length),
    );
  }

  static final _all = [
    _t(
      'p1',
      'Réceptionner la commande Sonelec',
      PlanningTaskType.reception,
      PlanningTaskStatus.todo,
      'u3',
      '2026-09-20',
      late: true,
    ),
    _t(
      'p2',
      'Compter les câbles souples',
      PlanningTaskType.count,
      PlanningTaskStatus.inProgress,
      'u3',
      '2026-09-23',
      zone: 'Zone A',
    ),
    _t(
      'p3',
      'Réviser les prix des disjoncteurs',
      PlanningTaskType.review,
      PlanningTaskStatus.todo,
      'u2',
      '2026-09-25',
    ),
    _t(
      'p4',
      'Saisir les nouveautés Legrand',
      PlanningTaskType.entry,
      PlanningTaskStatus.done,
      'u4',
      '2026-09-22',
      result: '14 références créées, photos jointes',
    ),
  ];
}

/// Une journée d'actions sensibles, telle que l'admin la relit.
class _CaptureAuditApi extends AuditApi {
  _CaptureAuditApi() : super(Dio());

  static AuditEntry _e(
    String id,
    AuditAction action,
    String type,
    String? who,
    DateTime at, {
    Map<String, dynamic>? before,
    Map<String, dynamic>? after,
  }) => AuditEntry(
    id: id,
    userId: who == null ? null : 'me',
    userName: who,
    action: action,
    entityType: type,
    entityId: 'x$id',
    oldValue: before,
    newValue: after,
    createdAt: at,
  );

  @override
  Future<AuditPage> list({
    int page = 1,
    int limit = 50,
    String? entityType,
    AuditAction? action,
    String? from,
  }) async => AuditPage(
    data: [
      _e(
        '1',
        AuditAction.update,
        'ProductPrice',
        'Radhi Badache',
        DateTime(2026, 9, 21, 14, 2),
        before: {'priceHt': 120000, 'priceTierId': 'detail'},
        after: {'priceHt': 135000, 'priceTierId': 'detail'},
      ),
      _e(
        '2',
        AuditAction.validate,
        'Inventory',
        'Radhi Badache',
        DateTime(2026, 9, 21, 11, 40),
        before: {'status': 'TERMINE'},
        after: {'status': 'TERMINE', 'adjustedLines': 2},
      ),
      _e(
        '3',
        AuditAction.cancel,
        'Sale',
        'Radhi Badache',
        DateTime(2026, 9, 21, 10, 15),
        before: {'status': 'VALIDEE', 'totalTtc': 1284000},
        after: {'status': 'ANNULEE', 'totalTtc': 1284000},
      ),
      _e(
        '4',
        AuditAction.update,
        'User',
        'Radhi Badache',
        DateTime(2026, 9, 21, 9, 5),
        before: {
          'roles': ['VENDEUR'],
        },
        after: {
          'roles': ['VENDEUR', 'MAGASINIER'],
        },
      ),
      _e(
        '5',
        AuditAction.update,
        'User',
        null,
        DateTime(2026, 9, 21, 8, 1),
        after: {'operation': 'REFRESH_TOKEN_REUSE_DETECTED'},
      ),
    ],
    meta: const PageMeta(page: 1, limit: 50, total: 5),
  );
}

class _CaptureSalesApi extends SalesApi {
  _CaptureSalesApi() : super(Dio());

  @override
  Future<CashSession?> currentCashSession() async => CashSession(
    id: 'cash',
    status: 'OUVERTE',
    openingFloat: 500000,
    cashSalesAmount: 1845000,
    cashSalesCount: 7,
    currentAmount: 2345000,
    openedAt: DateTime(2026, 9, 15, 8, 2),
  );

  @override
  Future<CashSessionPage> cashSessions({int limit = 100}) async =>
      CashSessionPage(
        data: [
          CashSession(
            id: 'cash',
            userFullName: 'Nadia Cherif',
            status: 'OUVERTE',
            openingFloat: 500000,
            cashSalesAmount: 1845000,
            cashSalesCount: 7,
            currentAmount: 2345000,
            openedAt: DateTime(2026, 9, 15, 8, 2),
          ),
          CashSession(
            id: 'cash-2',
            userFullName: 'Amine Benali',
            status: 'CLOTUREE',
            openingFloat: 500000,
            cashSalesAmount: 3120000,
            cashSalesCount: 14,
            currentAmount: 0,
            cashOutAmount: 250000,
            expectedAmount: 3370000,
            countedAmount: 3368000,
            difference: -2000,
            openedAt: DateTime(2026, 9, 14, 8, 10),
            closedAt: DateTime(2026, 9, 14, 18, 35),
          ),
        ],
        meta: const PageMeta(page: 1, limit: 100, total: 2),
      );

  @override
  Future<CustomerPage> customers({String? query, int limit = 50}) async =>
      const CustomerPage(
        data: [
          Customer(
            id: 'c1',
            name: 'SARL Électricité Benali',
            phone: '0550 12 34 56',
            priceTierId: 'gros',
            creditLimit: 5000000,
            balanceDue: 1284000,
            isActive: true,
          ),
          Customer(
            id: 'c2',
            name: 'Mourad Hamdi',
            phone: '0661 98 76 54',
            creditLimit: 0,
            balanceDue: 0,
            isActive: true,
          ),
          Customer(
            id: 'c3',
            name: 'Chantier Les Oliviers',
            creditLimit: 2000000,
            balanceDue: 1950000,
            isActive: true,
          ),
        ],
        meta: PageMeta(page: 1, limit: 50, total: 3),
      );
}

/// Vendeuse au comptoir : panier rempli à la douchette.
final _vendeuse = authUser(
  id: 'v',
  fullName: 'Nadia Kaci',
  roles: const ['VENDEUR'],
  permissions: const [
    'product.read',
    'stock.read.store',
    'sale.create',
    'sale.credit',
    'invoice.issue',
    'cash.session.manage',
    'customer.read',
    'customer.write',
    'customer.payment.create',
  ],
);

final _priced = [
  for (final (p, ht) in [
    (_products[0], 14500),
    (_products[1], 89000),
    (_products[2], 1250000),
    (_products[3], 185000),
    (_products[4], 420000),
  ])
    p.copyWith(
      taxRateId: 'tva19',
      prices: [ProductPriceLine(priceTierId: 'detail', priceHt: ht)],
    ),
];

Future<void> _fillCart(WidgetTester t) async {
  await t.tap(find.text('Vente'));
  await t.pumpAndSettle();
  for (final code in [
    '3245060123458',
    '3245064074152',
    '3245064074152',
    '2000000000022',
  ]) {
    await t.enterText(find.byType(TextField).first, code);
    await t.testTextInput.receiveAction(TextInputAction.done);
    await t.pumpAndSettle();
  }
}

Future<void> _loadFonts() async {
  final archivo = FontLoader('Archivo')
    ..addFont(rootBundle.load('fonts/Archivo-Variable.ttf'));
  final lucide = FontLoader('packages/lucide_icons_flutter/Lucide')
    ..addFont(
      rootBundle.load('packages/lucide_icons_flutter/assets/lucide.ttf'),
    );
  await Future.wait([archivo.load(), lucide.load()]);
}

Future<void> _capture(
  WidgetTester tester, {
  required String name,
  required Size size,
  required Widget home,
  bool dark = true,
  AuthController Function()? auth,
  AuthUser? user,
  int foreignPending = 0,
  Future<void> Function(WidgetTester)? interact,
  List<Product>? products,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final db = AppDatabase.forTesting();
  final key = GlobalKey();

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authControllerProvider.overrideWith(
          auth ??
              () => _SignedIn(
                user ??
                    authUser(
                      id: 'me',
                      fullName: 'Radhi Badache',
                      permissions: _adminPermissions,
                    ),
              ),
        ),
        catalogSyncProvider.overrideWith(_IdleSync.new),
        productsProvider.overrideWith(
          (ref) => Stream.value(products ?? _products),
        ),
        categoriesProvider.overrideWith((ref) => Stream.value(_categories)),
        locationsProvider.overrideWith((ref) => Stream.value(_locations)),
        taxRatesProvider.overrideWith(
          (ref) => Stream.value([
            TaxRate(
              id: 'tva19',
              code: 'TVA19',
              name: 'TVA 19 %',
              rate: '19.00',
              isDefault: true,
              isActive: true,
              updatedAt: DateTime.utc(2026),
            ),
          ]),
        ),
        activeProductsProvider.overrideWith(
          (ref) => Stream.value(products ?? _products),
        ),
        priceTiersProvider.overrideWith(
          (ref) async => const [
            PriceTier(
              id: 'detail',
              code: 'DETAIL',
              name: 'Détail',
              isDefault: true,
            ),
            PriceTier(id: 'gros', code: 'GROS', name: 'Gros', isDefault: false),
          ],
        ),
        salesApiProvider.overrideWithValue(_CaptureSalesApi()),
        suppliersApiProvider.overrideWithValue(_CaptureSuppliersApi()),
        purchasesApiProvider.overrideWithValue(_CapturePurchasesApi()),
        receptionsApiProvider.overrideWithValue(_CaptureReceptionsApi()),
        transfersApiProvider.overrideWithValue(_CaptureTransfersApi()),
        inventoryApiProvider.overrideWithValue(_CaptureInventoryApi()),
        planningApiProvider.overrideWithValue(_CapturePlanningApi()),
        auditApiProvider.overrideWithValue(_CaptureAuditApi()),
        stockByProductProvider.overrideWith((ref) async => _stockByProduct),
        stockApiProvider.overrideWithValue(_CaptureStockApi()),
        appDatabaseProvider.overrideWithValue(db),
        usersApiProvider.overrideWithValue(FakeUsersApi(users: _users)),
        currentUserIdProvider.overrideWithValue('me'),
        documentCacheProvider.overrideWithValue(MemoryDocumentCache()),
        pendingMutationsCountProvider.overrideWith((ref) => Stream.value(0)),
        foreignPendingMutationsCountProvider.overrideWith(
          (ref) => Stream.value(foreignPending),
        ),
        rejectedMutationsProvider.overrideWith((ref) => Stream.value(const [])),
      ],
      child: RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          builder: (context, child) => Theme(
            data: isDesktopWidth(MediaQuery.sizeOf(context).width)
                ? AppTheme.desktop(dark: dark)
                : AppTheme.mobile(dark: dark),
            child: child!,
          ),
          home: home,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  if (interact != null) {
    await interact(tester);
    await tester.pumpAndSettle();
  }

  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    File('$out/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
  });
  // Un champ de saisie FOCALISÉ fait clignoter son curseur : c'est une
  // minuterie qui survit au démontage et fait échouer le test après coup. On
  // rend le focus avant de démonter, puis on laisse expirer le reste
  // (bandeaux, infobulles, animations de dialogue).
  tester.binding.focusManager.primaryFocus?.unfocus();
  await tester.pump();
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 10));
  await tester.runAsync(db.close);
}

/// Mobile : l'admin a plus de 4 destinations, les dernières sont sous « Plus ».
Future<void> _viaMore(WidgetTester t, String label) async {
  await t.tap(find.text('Plus'));
  await t.pumpAndSettle();
  // Le menu défile : l'entrée peut être sous le pli.
  await t.ensureVisible(find.text(label));
  await t.pumpAndSettle();
  await t.tap(find.text(label));
}

void main() {
  setUpAll(_loadFonts);
  const skip = out == '';

  testWidgets(
    '01 login desktop sombre',
    skip: skip,
    (t) => _capture(
      t,
      name: '01_login_desktop_sombre',
      size: const Size(1440, 900),
      home: const LoginScreen(),
      auth: _SignedOut.new,
    ),
  );
  testWidgets(
    '02 login mobile clair',
    skip: skip,
    (t) => _capture(
      t,
      name: '02_login_mobile_clair',
      size: const Size(390, 844),
      home: const LoginScreen(),
      auth: _SignedOut.new,
      dark: false,
    ),
  );
  testWidgets(
    '03 mot de passe force mobile',
    skip: skip,
    (t) => _capture(
      t,
      name: '03_mdp_force_mobile',
      size: const Size(390, 844),
      home: const ChangePasswordScreen(),
    ),
  );
  testWidgets(
    '04 utilisateurs desktop sombre',
    skip: skip,
    (t) => _capture(
      t,
      name: '04_utilisateurs_desktop_sombre',
      size: const Size(1440, 900),
      home: const AdaptiveShell(),
      interact: (t) async => t.tap(find.text('Utilisateurs')),
    ),
  );
  testWidgets(
    '05 utilisateurs desktop clair',
    skip: skip,
    (t) => _capture(
      t,
      name: '05_utilisateurs_desktop_clair',
      size: const Size(1440, 900),
      home: const AdaptiveShell(),
      dark: false,
      interact: (t) async => t.tap(find.text('Utilisateurs')),
    ),
  );
  testWidgets(
    '06 formulaire panneau desktop',
    skip: skip,
    (t) => _capture(
      t,
      name: '06_formulaire_panneau_desktop',
      size: const Size(1440, 900),
      home: const AdaptiveShell(),
      interact: (t) async {
        await t.tap(find.text('Utilisateurs'));
        await t.pumpAndSettle();
        await t.tap(find.text('Karim Saidi'));
      },
    ),
  );
  testWidgets(
    '07 tablette rail',
    skip: skip,
    (t) => _capture(
      t,
      name: '07_tablette_rail',
      size: const Size(1024, 768),
      home: const AdaptiveShell(),
      interact: (t) async => t.tap(find.byTooltip('Utilisateurs')),
    ),
  );
  testWidgets(
    '08 utilisateurs mobile sombre',
    skip: skip,
    (t) => _capture(
      t,
      name: '08_utilisateurs_mobile_sombre',
      size: const Size(390, 844),
      home: const AdaptiveShell(),
      interact: (t) => _viaMore(t, 'Utilisateurs'),
    ),
  );
  testWidgets(
    '09 formulaire plein ecran mobile',
    skip: skip,
    (t) => _capture(
      t,
      name: '09_formulaire_mobile',
      size: const Size(390, 844),
      home: const AdaptiveShell(),
      interact: (t) async {
        await _viaMore(t, 'Utilisateurs');
        await t.pumpAndSettle();
        await t.tap(find.text('Nouveau'));
      },
    ),
  );
  testWidgets(
    '10 confirmation danger desktop',
    skip: skip,
    (t) => _capture(
      t,
      name: '10_confirmation_danger',
      size: const Size(1440, 900),
      home: const AdaptiveShell(),
      interact: (t) async {
        await t.tap(find.text('Utilisateurs'));
        await t.pumpAndSettle();
        await t.tap(find.byTooltip('Actions').at(1));
        await t.pumpAndSettle();
        await t.tap(find.text('Désactiver'));
      },
    ),
  );
  testWidgets(
    '11 profil mobile',
    skip: skip,
    (t) => _capture(
      t,
      name: '11_profil_mobile',
      size: const Size(390, 844),
      home: const AdaptiveShell(),
      foreignPending: 2,
      interact: (t) => _viaMore(t, 'Mon profil'),
    ),
  );

  testWidgets(
    '12 catalogue desktop sombre',
    skip: skip,
    (t) => _capture(
      t,
      name: '12_catalogue_desktop_sombre',
      size: const Size(1440, 900),
      home: const AdaptiveShell(),
      interact: (t) async => t.tap(find.text('Catalogue')),
    ),
  );
  testWidgets(
    '13 fiche produit panneau desktop',
    skip: skip,
    (t) => _capture(
      t,
      name: '13_produit_panneau_desktop',
      size: const Size(1440, 900),
      home: const AdaptiveShell(),
      interact: (t) async {
        await t.tap(find.text('Catalogue'));
        await t.pumpAndSettle();
        await t.tap(find.text('Disjoncteur DX³ 16A courbe C'));
      },
    ),
  );
  testWidgets(
    '14 catalogue mobile clair vendeur',
    skip: skip,
    (t) => _capture(
      t,
      name: '14_catalogue_mobile_clair_vendeur',
      size: const Size(390, 844),
      home: const AdaptiveShell(),
      dark: false,
      user: authUser(
        id: 'v',
        fullName: 'Amine Benali',
        roles: const ['VENDEUR'],
        permissions: const ['product.read', 'price.read'],
      ),
      interact: (t) async => t.tap(find.text('Catalogue')),
    ),
  );
  testWidgets(
    '15 categories desktop',
    skip: skip,
    (t) => _capture(
      t,
      name: '15_categories_desktop',
      size: const Size(1440, 900),
      home: const AdaptiveShell(),
      interact: (t) async {
        await t.tap(find.text('Catalogue'));
        await t.pumpAndSettle();
        await t.tap(find.text('Catégories'));
      },
    ),
  );
  testWidgets(
    '16 emplacements mobile magasinier',
    skip: skip,
    (t) => _capture(
      t,
      name: '16_emplacements_mobile_magasinier',
      size: const Size(390, 844),
      home: const AdaptiveShell(),
      user: authUser(
        id: 'm',
        fullName: 'Karim Saidi',
        roles: const ['MAGASINIER'],
        permissions: const ['product.read', 'location.manage'],
      ),
      interact: (t) async {
        await t.tap(find.text('Catalogue'));
        await t.pumpAndSettle();
        await t.tap(find.text('Emplacements'));
      },
    ),
  );
  testWidgets(
    '17 nouveau produit mobile',
    skip: skip,
    (t) => _capture(
      t,
      name: '17_nouveau_produit_mobile',
      size: const Size(390, 844),
      home: const AdaptiveShell(),
      interact: (t) async {
        await t.tap(find.text('Catalogue'));
        await t.pumpAndSettle();
        await t.tap(find.text('Nouveau'));
      },
    ),
  );

  testWidgets(
    '18 stock desktop',
    skip: skip,
    (t) => _capture(
      t,
      name: '18_stock_desktop',
      size: const Size(1440, 900),
      home: const AdaptiveShell(),
      interact: (t) async => t.tap(find.text('Stock')),
    ),
  );
  testWidgets(
    '19 pertes a valider admin mobile',
    skip: skip,
    (t) => _capture(
      t,
      name: '19_pertes_admin_mobile',
      size: const Size(390, 844),
      home: const AdaptiveShell(),
      interact: (t) async {
        await _viaMore(t, 'Stock');
        await t.pumpAndSettle();
        await t.tap(find.text('Pertes'));
      },
    ),
  );
  testWidgets(
    '20 declarer perte magasinier mobile',
    skip: skip,
    (t) => _capture(
      t,
      name: '20_declarer_perte_magasinier',
      size: const Size(390, 844),
      home: const AdaptiveShell(),
      user: authUser(
        id: 'm',
        fullName: 'Karim Saidi',
        roles: const ['MAGASINIER'],
        permissions: const [
          'product.read',
          'location.manage',
          'stock.read.store',
          'stock.read.warehouse',
          'stock.loss',
        ],
      ),
      interact: (t) async {
        await t.tap(find.text('Stock'));
        await t.pumpAndSettle();
        await t.tap(find.text('Pertes'));
        await t.pumpAndSettle();
        await t.tap(find.text('Déclarer une perte'));
      },
    ),
  );

  testWidgets(
    '21 vente desktop vendeuse',
    skip: skip,
    (t) => _capture(
      t,
      name: '21_vente_desktop',
      size: const Size(1440, 900),
      home: const AdaptiveShell(),
      user: _vendeuse,
      products: _priced,
      interact: _fillCart,
    ),
  );
  testWidgets(
    '22 vente mobile vendeuse',
    skip: skip,
    (t) => _capture(
      t,
      name: '22_vente_mobile',
      size: const Size(390, 844),
      home: const AdaptiveShell(),
      user: _vendeuse,
      products: _priced,
      interact: _fillCart,
    ),
  );
  testWidgets(
    '23 clients mobile vendeuse',
    skip: skip,
    (t) => _capture(
      t,
      name: '23_clients_mobile',
      size: const Size(390, 844),
      home: const AdaptiveShell(),
      user: _vendeuse,
      products: _priced,
      interact: (t) async {
        await t.tap(find.text('Vente'));
        await t.pumpAndSettle();
        await t.tap(find.text('Clients'));
      },
    ),
  );

  testWidgets(
    '24 fournisseurs desktop',
    skip: skip,
    (t) => _capture(
      t,
      name: '24_fournisseurs_desktop',
      size: const Size(1440, 900),
      home: const AdaptiveShell(),
      interact: (t) async => t.tap(find.text('Fournisseurs')),
    ),
  );
  testWidgets(
    '25 paiement fournisseur mobile',
    skip: skip,
    (t) => _capture(
      t,
      name: '25_paiement_fournisseur_mobile',
      size: const Size(390, 844),
      home: const AdaptiveShell(),
      interact: (t) async {
        await _viaMore(t, 'Fournisseurs');
        await t.pumpAndSettle();
        await t.tap(find.text('Sonelgaz Matériel'));
        await t.pumpAndSettle();
        await t.tap(find.text('Enregistrer un paiement'));
      },
    ),
  );

  testWidgets(
    '26 achats desktop',
    skip: skip,
    (t) => _capture(
      t,
      name: '26_achats_desktop',
      size: const Size(1440, 900),
      home: const AdaptiveShell(),
      interact: (t) async => t.tap(find.text('Achats')),
    ),
  );
  testWidgets(
    '27 nouvelle commande desktop',
    skip: skip,
    (t) => _capture(
      t,
      name: '27_nouvelle_commande_desktop',
      size: const Size(1440, 900),
      home: const AdaptiveShell(),
      interact: (t) async {
        await t.tap(find.text('Achats'));
        await t.pumpAndSettle();
        await t.tap(find.text('Nouvelle commande'));
      },
    ),
  );

  testWidgets(
    '28 réception d’une commande desktop',
    skip: skip,
    (t) => _capture(
      t,
      name: '28_reception_desktop',
      size: const Size(1440, 900),
      home: const AdaptiveShell(),
      interact: (t) async {
        await t.tap(find.text('Achats'));
        await t.pumpAndSettle();
        await t.tap(find.textContaining('BC-2026-00005'));
        await t.pumpAndSettle();
        await t.tap(find.text('Réceptionner la marchandise'));
      },
    ),
  );
  testWidgets(
    '29 réception mobile',
    skip: skip,
    (t) => _capture(
      t,
      name: '29_reception_mobile',
      size: const Size(390, 844),
      home: const AdaptiveShell(),
      interact: (t) async {
        await _viaMore(t, 'Achats');
        await t.pumpAndSettle();
        await t.tap(find.textContaining('BC-2026-00005'));
        await t.pumpAndSettle();
        await t.tap(find.text('Réceptionner la marchandise'));
      },
    ),
  );
  testWidgets(
    '30 clôture du reliquat desktop',
    skip: skip,
    (t) => _capture(
      t,
      name: '30_cloture_reliquat_desktop',
      size: const Size(1440, 900),
      home: const AdaptiveShell(),
      interact: (t) async {
        await t.tap(find.text('Achats'));
        await t.pumpAndSettle();
        await t.tap(find.textContaining('BC-2026-00005'));
        await t.pumpAndSettle();
        await t.tap(find.text('Clôturer le reliquat'));
      },
    ),
  );
  testWidgets(
    '31 caisses (admin) desktop',
    skip: skip,
    (t) => _capture(
      t,
      name: '31_caisses_desktop',
      size: const Size(1440, 900),
      home: const AdaptiveShell(),
      interact: (t) async {
        await t.tap(find.text('Vente'));
        await t.pumpAndSettle();
        await t.tap(find.text('Caisses'));
      },
    ),
  );
  testWidgets(
    '32 transferts desktop',
    skip: skip,
    (t) => _capture(
      t,
      name: '32_transferts_desktop',
      size: const Size(1440, 900),
      home: const AdaptiveShell(),
      interact: (t) async => t.tap(find.text('Transferts')),
    ),
  );
  testWidgets(
    '33 demande au dépôt mobile',
    skip: skip,
    (t) => _capture(
      t,
      name: '33_demande_depot_mobile',
      size: const Size(390, 844),
      home: const AdaptiveShell(),
      interact: (t) async {
        await _viaMore(t, 'Transferts');
        await t.pumpAndSettle();
        await t.tap(find.text('Nouvelle demande'));
      },
    ),
  );
  testWidgets(
    '34 préparation du transfert mobile',
    skip: skip,
    (t) => _capture(
      t,
      name: '34_preparation_transfert_mobile',
      size: const Size(390, 844),
      home: const AdaptiveShell(),
      interact: (t) async {
        await _viaMore(t, 'Transferts');
        await t.pumpAndSettle();
        await t.tap(find.textContaining('TRF-2026-00003'));
        await t.pumpAndSettle();
        await t.tap(find.text('Corriger la préparation'));
      },
    ),
  );
  testWidgets(
    '36 inventaire desktop',
    skip: skip,
    (t) => _capture(
      t,
      name: '36_inventaire_desktop',
      size: const Size(1440, 900),
      home: const AdaptiveShell(),
      interact: (t) async => t.tap(find.text('Inventaire')),
    ),
  );
  testWidgets(
    '37 comptage d’inventaire mobile',
    skip: skip,
    (t) => _capture(
      t,
      name: '37_comptage_inventaire_mobile',
      size: const Size(390, 844),
      home: const AdaptiveShell(),
      interact: (t) async {
        await _viaMore(t, 'Inventaire');
        await t.pumpAndSettle();
        await t.tap(find.text('INV-2026-00003'));
        await t.pumpAndSettle();
        await t.tap(find.text('Reprendre le comptage'));
      },
    ),
  );
  testWidgets(
    '38 écarts d’inventaire à valider desktop',
    skip: skip,
    (t) => _capture(
      t,
      name: '38_ecarts_inventaire_desktop',
      size: const Size(1440, 900),
      home: const AdaptiveShell(),
      interact: (t) async {
        await t.tap(find.text('Inventaire'));
        await t.pumpAndSettle();
        await t.tap(find.text('INV-2026-00002'));
        await t.pumpAndSettle();
        await t.tap(find.text('Voir les écarts'));
      },
    ),
  );
  testWidgets(
    '39 planning de l’équipe desktop',
    skip: skip,
    (t) => _capture(
      t,
      name: '39_planning_desktop',
      size: const Size(1440, 900),
      home: const AdaptiveShell(),
      interact: (t) async => t.tap(find.text('Tâches')),
    ),
  );
  testWidgets(
    '40 nouvelle tâche desktop',
    skip: skip,
    (t) => _capture(
      t,
      name: '40_nouvelle_tache_desktop',
      size: const Size(1440, 900),
      home: const AdaptiveShell(),
      interact: (t) async {
        await t.tap(find.text('Tâches'));
        await t.pumpAndSettle();
        await t.tap(find.text('Nouvelle tâche'));
      },
    ),
  );
  testWidgets(
    '41 fin de tâche mobile',
    skip: skip,
    (t) => _capture(
      t,
      name: '41_fin_de_tache_mobile',
      size: const Size(390, 844),
      home: const AdaptiveShell(),
      interact: (t) async {
        await _viaMore(t, 'Tâches');
        await t.pumpAndSettle();
        await t.tap(find.text('Compter les câbles souples'));
        await t.pumpAndSettle();
        await t.tap(find.text('Terminer et donner le résultat'));
      },
    ),
  );
  testWidgets(
    '44 résultat de scan mobile',
    skip: skip,
    (t) => _capture(
      t,
      name: '44_scan_mobile',
      size: const Size(390, 844),
      products: _priced,
      // L'écran caméra ne se capture pas (pas de caméra en test) : on capture
      // ce qu'il montre APRÈS le scan (spec §27).
      home: Builder(
        builder: (context) => Scaffold(
          appBar: AppBar(title: const Text('Scanner')),
          body: ScannedProductSheet(
            barcode: '3245060123458',
            user: authUser(
              id: 'me',
              fullName: 'Radhi Badache',
              permissions: _adminPermissions,
            ),
          ),
        ),
      ),
    ),
  );
  testWidgets(
    '42 historique desktop',
    skip: skip,
    (t) => _capture(
      t,
      name: '42_historique_desktop',
      size: const Size(1440, 900),
      home: const AdaptiveShell(),
      interact: (t) async => t.tap(find.text('Historique')),
    ),
  );
  testWidgets(
    '43 détail d’une modification de prix desktop',
    skip: skip,
    (t) => _capture(
      t,
      name: '43_historique_detail_desktop',
      size: const Size(1440, 900),
      home: const AdaptiveShell(),
      interact: (t) async {
        await t.tap(find.text('Historique'));
        await t.pumpAndSettle();
        await t.tap(find.text('Prix · Modification'));
      },
    ),
  );
  testWidgets(
    '35 réception du transfert desktop',
    skip: skip,
    (t) => _capture(
      t,
      name: '35_reception_transfert_desktop',
      size: const Size(1440, 900),
      home: const AdaptiveShell(),
      interact: (t) async {
        await t.tap(find.text('Transferts'));
        await t.pumpAndSettle();
        await t.tap(find.textContaining('TRF-2026-00002'));
        await t.pumpAndSettle();
        await t.tap(find.text('Réceptionner au magasin'));
      },
    ),
  );
}
