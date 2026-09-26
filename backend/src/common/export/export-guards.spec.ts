import { FRESH_READ_KEY, PERMISSIONS_KEY, ROLES_KEY } from '../auth.decorators';
import { CustomersController } from '../../customers/customers.controller';
import { InventoryController } from '../../inventory/inventory.controller';
import { PurchaseOrdersController } from '../../purchases/purchase-orders.controller';
import { ReceptionsController } from '../../receptions/receptions.controller';
import { BusinessReportController } from '../../reports/business-report.controller';
import { SalesController } from '../../sales/sales.controller';
import { StockController } from '../../stock/stock.controller';
import { SuppliersController } from '../../suppliers/suppliers.controller';

/// « Un fichier n'est pas un contournement de permission », prouvé par les
/// MÉTADONNÉES : chaque route d'export porte exactement les rôles et les
/// permissions de la lecture qu'elle exporte, et au moins sa relecture des
/// droits en base. Le test e2e de parité ne voit que les rôles par défaut —
/// qui ont tous leurs permissions —, donc il ne verrait pas une
/// `@RequirePermissions` oubliée. Celui-ci si.
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type Controller = { prototype: any };

const PAIRS: [Controller, string, string][] = [
  [SalesController, 'findAll', 'export'],
  [CustomersController, 'findAll', 'export'],
  [SuppliersController, 'findAll', 'export'],
  [StockController, 'findAll', 'exportStock'],
  [StockController, 'movements', 'exportMovements'],
  [InventoryController, 'findAll', 'export'],
  [PurchaseOrdersController, 'findAll', 'export'],
  [ReceptionsController, 'findAll', 'export'],
  [BusinessReportController, 'sales', 'salesExport'],
  [BusinessReportController, 'stock', 'stockExport'],
  [BusinessReportController, 'purchases', 'purchasesExport'],
];

const meta = (controller: Controller, method: string, key: string): unknown =>
  Reflect.getMetadata(key, controller.prototype[method]);

describe('gardes des exports = gardes de la lecture exportée', () => {
  it.each(PAIRS)('%p.%s → %s', (controller, read, exported) => {
    expect(controller.prototype[exported]).toBeDefined();
    expect(meta(controller, exported, ROLES_KEY)).toEqual(
      meta(controller, read, ROLES_KEY),
    );
    expect(meta(controller, exported, PERMISSIONS_KEY)).toEqual(
      meta(controller, read, PERMISSIONS_KEY),
    );
    // Rôle ET permission : jamais une route d'export sans garde explicite.
    expect(meta(controller, exported, ROLES_KEY)).toBeTruthy();
    // Un export de masse relit toujours les droits en base.
    expect(meta(controller, exported, FRESH_READ_KEY)).toBe(true);
  });
});
