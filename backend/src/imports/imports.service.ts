import { HttpStatus, Injectable } from '@nestjs/common';
import { plainToInstance } from 'class-transformer';
import { validate } from 'class-validator';
import { ActorContext } from '../audit/audit-writer';
import { BusinessException } from '../common/business.exception';
import { ErrorCode } from '../common/error-codes';
import {
  ExportDocument,
  renderExport,
  ExportFormat,
  ExportFile,
  section,
} from '../common/export/export';
import { label } from '../common/export/labels';
import {
  ImportRow,
  parseImportQuantity,
  parseMoney,
  readTable,
} from '../common/export/import';
import { flatten } from '../common/validate-payload';
import { CreateCustomerDto } from '../customers/dto/customer.dto';
import { CustomersService } from '../customers/customers.service';
import { Prisma } from '../generated/prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import { CreateProductDto, ProductUnitDto } from '../products/dto/product.dto';
import { ProductsService } from '../products/products.service';
import { CreateSupplierDto } from '../suppliers/dto/supplier.dto';
import { SuppliersService } from '../suppliers/suppliers.service';
import { ImportReportDto } from './dto/import.dto';

type Db = Prisma.TransactionClient;
export type ImportKind = 'products' | 'customers' | 'suppliers';

/// Verrou d'import : deux imports simultanés du même fichier ne créent pas
/// deux fois les mêmes fiches (les doublons sont recontrôlés SOUS ce verrou).
const IMPORT_LOCK = 7304;

/// Délai d'une transaction d'import : 1 000 produits avec leurs prix et leur
/// stock initial, c'est quelques milliers de requêtes (le défaut Prisma est
/// 5 s). ponytail : un import est une mise en place ponctuelle ; il tient les
/// écritures de produits pendant sa durée.
const IMPORT_TIMEOUT_MS = 120_000;

interface Prepared<Dto> {
  line: number;
  label: string;
  dto: Dto;
  prices?: { priceTierId: string; priceHt: number }[];
}

/// Import Excel/CSV (spec §8quinquies, P1 n°21c) : produits (avec prix et
/// stock initial), clients, fournisseurs. CRÉATION seulement — un import ne
/// modifie jamais une fiche existante (un doublon est une erreur signalée).
///
/// Deux temps : `dryRun` vérifie TOUTES les lignes et les rapporte sans rien
/// écrire ; l'application refait la vérification puis crée tout dans UNE
/// transaction — tout ou rien (règle 3). Chaque ligne passe par le DTO et le
/// cœur de création de la route unitaire : mêmes règles, même audit, stock
/// initial par le journal (règle 2).
@Injectable()
export class ImportsService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly products: ProductsService,
    private readonly customers: CustomersService,
    private readonly suppliers: SuppliersService,
  ) {}

  // ── Colonnes ────────────────────────────────────────────────────────────

  private async productColumns() {
    const tiers = await this.prisma.priceTier.findMany({
      where: { isActive: true },
      orderBy: { isDefault: 'desc' },
    });
    return {
      tiers: tiers.map((t) => ({ ...t, header: `Prix ${t.name} HT` })),
      headers: [
        'Référence',
        'Nom',
        'Code-barres',
        'Unité',
        'Catégorie',
        'TVA %',
        'Marque',
        'Seuil minimum',
        ...tiers.map((t) => `Prix ${t.name} HT`),
        'Stock magasin',
        'Stock dépôt',
      ],
      required: ['Référence', 'Nom'],
    };
  }

  private static readonly CUSTOMER_HEADERS = [
    'Nom',
    'Téléphone',
    'E-mail',
    'Adresse',
    'Plafond de crédit',
    'Notes',
  ];

  private static readonly SUPPLIER_HEADERS = [
    'Nom',
    'Contact',
    'Téléphone',
    'E-mail',
    'Adresse',
    'Reprise de dette',
    'Notes',
  ];

  // ── Modèle à remplir ────────────────────────────────────────────────────

  /// Modèle vide (en-têtes + une ligne d'exemple) : c'est lui qu'on remplit.
  async template(kind: ImportKind, format: ExportFormat): Promise<ExportFile> {
    const example: Record<ImportKind, () => Promise<ExportDocument>> = {
      products: async () => {
        const { headers, tiers } = await this.productColumns();
        const row: Record<string, string> = {
          Référence: 'CAB-3G25',
          Nom: 'Câble 3G2,5 (rouleau de 100 m)',
          'Code-barres': '',
          Unité: 'Mètre',
          Catégorie: '',
          'TVA %': '19',
          Marque: '',
          'Seuil minimum': '100',
          'Stock magasin': '250',
          'Stock dépôt': '1000',
        };
        tiers.forEach((t, i) => (row[t.header] = i === 0 ? '145,00' : ''));
        return ImportsService.templateDocument('Import produits', headers, row);
      },
      customers: () =>
        Promise.resolve(
          ImportsService.templateDocument(
            'Import clients',
            ImportsService.CUSTOMER_HEADERS,
            {
              Nom: 'Électricité Benali',
              Téléphone: '0550 12 34 56',
              'Plafond de crédit': '50000,00',
            },
          ),
        ),
      suppliers: () =>
        Promise.resolve(
          ImportsService.templateDocument(
            'Import fournisseurs',
            ImportsService.SUPPLIER_HEADERS,
            {
              Nom: 'Sonelec',
              Contact: 'M. Rahmani',
              Téléphone: '0550 11 22 33',
              'Reprise de dette': '0,00',
            },
          ),
        ),
    };
    return renderExport(await example[kind](), format);
  }

  private static templateDocument(
    title: string,
    headers: string[],
    example: Record<string, string>,
  ): ExportDocument {
    return {
      title,
      subtitle:
        'Une ligne par fiche, à partir de la ligne d’exemple (à remplacer). ' +
        'Montants en dinars (1725,50), quantités décimales (12,5).',
      filename: title.toLowerCase().replace(/\s+/g, '-'),
      sections: [
        section({
          columns: headers.map((h) => ({
            header: h,
            value: (r: Record<string, string>) => r[h] ?? '',
          })),
          rows: [example],
        }),
      ],
    };
  }

  // ── Import ──────────────────────────────────────────────────────────────

  async importFile(
    kind: ImportKind,
    file: Buffer,
    dryRun: boolean,
    actor: ActorContext,
  ): Promise<ImportReportDto> {
    const prepared = await this.prepare(kind, file);
    const errors = prepared.errors;
    const report = (created: number): ImportReportDto => ({
      kind,
      dryRun,
      total: prepared.rows.length + errors.length,
      created,
      errors,
    });
    if (dryRun) return report(0);
    if (errors.length > 0) {
      throw new BusinessException(
        ErrorCode.VALIDATION_FAILED,
        `Import refusé : ${errors.length} ligne(s) en erreur — rien n’a été créé`,
        HttpStatus.UNPROCESSABLE_ENTITY,
      );
    }
    await this.prisma.$transaction(
      async (tx) => {
        await tx.$executeRaw`SELECT pg_advisory_xact_lock(${IMPORT_LOCK}::int, 0)`;
        // Doublons recontrôlés SOUS le verrou : un import concurrent est passé
        // entre la vérification et l'écriture.
        const late = await this.duplicates(tx, kind, prepared.rows);
        if (late.length > 0) {
          throw new BusinessException(
            ErrorCode.CONFLICT,
            `Import refusé : ${late[0].message} (ligne ${late[0].line}) — rien n’a été créé`,
            HttpStatus.CONFLICT,
          );
        }
        for (const row of prepared.rows) {
          await this.createRow(tx, kind, row, actor).catch((error: unknown) => {
            // Refus métier d'une ligne (ex. code-barres pris) : on le rapporte
            // AVEC sa ligne, et toute la transaction est annulée.
            if (error instanceof BusinessException) {
              const message = (error.getResponse() as { message?: string })
                .message;
              throw new BusinessException(
                ErrorCode.VALIDATION_FAILED,
                `Ligne ${row.line} (${row.label}) : ${message} — rien n’a été créé`,
                HttpStatus.UNPROCESSABLE_ENTITY,
              );
            }
            throw error;
          });
        }
      },
      { timeout: IMPORT_TIMEOUT_MS, maxWait: 10_000 },
    );
    return report(prepared.rows.length);
  }

  private async createRow(
    tx: Db,
    kind: ImportKind,
    row: Prepared<object>,
    actor: ActorContext,
  ) {
    if (kind === 'products') {
      const product = await this.products.createInTx(
        tx,
        row.dto as CreateProductDto,
        actor,
      );
      for (const price of row.prices ?? []) {
        await this.products.setPriceInTx(tx, product.id, price, actor);
      }
    } else if (kind === 'customers') {
      await this.customers.createInTx(tx, row.dto as CreateCustomerDto, actor);
    } else {
      await this.suppliers.createInTx(tx, row.dto as CreateSupplierDto, actor);
    }
  }

  /// Lit le fichier et prépare chaque ligne : DTO de création, validé comme
  /// par la route unitaire, références résolues, doublons repérés. Rend les
  /// lignes prêtes ET toutes les erreurs — jamais la première seulement.
  private async prepare(kind: ImportKind, file: Buffer) {
    const errors: { line: number; message: string }[] = [];
    const rows: Prepared<object>[] = [];
    const fail = (line: number, message: string) =>
      errors.push({ line, message });

    let table: ImportRow[];
    let build: (row: ImportRow) => Promise<Prepared<object> | string>;
    if (kind === 'products') {
      const columns = await this.productColumns();
      table = await readTable(file, columns.headers, columns.required);
      build = await this.productBuilder(columns.tiers);
    } else if (kind === 'customers') {
      table = await readTable(file, ImportsService.CUSTOMER_HEADERS, ['Nom']);
      build = (row) => ImportsService.customerRow(row);
    } else {
      table = await readTable(file, ImportsService.SUPPLIER_HEADERS, ['Nom']);
      build = (row) => ImportsService.supplierRow(row);
    }

    for (const row of table) {
      const built = await build(row);
      if (typeof built === 'string') {
        fail(row.line, built);
        continue;
      }
      const dtoClass: new () => object =
        kind === 'products'
          ? CreateProductDto
          : kind === 'customers'
            ? CreateCustomerDto
            : CreateSupplierDto;
      const invalid = flatten(
        await validate(plainToInstance(dtoClass, built.dto), {
          whitelist: true,
          forbidNonWhitelisted: true,
        }),
      );
      if (invalid.length > 0) {
        fail(row.line, invalid.join(' ; '));
        continue;
      }
      rows.push(built);
    }
    for (const duplicate of await this.duplicates(this.prisma, kind, rows)) {
      fail(duplicate.line, duplicate.message);
    }
    errors.sort((a, b) => a.line - b.line);
    const bad = new Set(errors.map((e) => e.line));
    return { rows: rows.filter((r) => !bad.has(r.line)), errors };
  }

  /// Doublons DANS le fichier et avec la base : référence et code-barres pour
  /// un produit, nom pour un client ou un fournisseur (aucun autre identifiant
  /// commun). Un import ne crée jamais une seconde fiche.
  private async duplicates(
    db: Db | PrismaService,
    kind: ImportKind,
    rows: Prepared<object>[],
  ) {
    const found: { line: number; message: string }[] = [];
    const seen = new Map<string, number>();
    const inFile = (key: string, line: number, what: string) => {
      const first = seen.get(key);
      if (first !== undefined) {
        found.push({
          line,
          message: `${what} en double (déjà ligne ${first})`,
        });
      } else {
        seen.set(key, line);
      }
    };
    if (kind === 'products') {
      const dtos = rows.map((r) => ({
        line: r.line,
        dto: r.dto as CreateProductDto,
      }));
      for (const { line, dto } of dtos) {
        inFile(
          `sku:${dto.sku.toLowerCase()}`,
          line,
          `Référence « ${dto.sku} »`,
        );
        if (dto.barcode)
          inFile(`bc:${dto.barcode}`, line, `Code-barres « ${dto.barcode} »`);
      }
      const existing = await db.product.findMany({
        where: {
          OR: [
            { sku: { in: dtos.map((d) => d.dto.sku), mode: 'insensitive' } },
            {
              barcode: {
                in: dtos.flatMap((d) => (d.dto.barcode ? [d.dto.barcode] : [])),
              },
            },
          ],
        },
        select: { sku: true, barcode: true },
      });
      const skus = new Set(existing.map((p) => p.sku.toLowerCase()));
      const codes = new Set(existing.map((p) => p.barcode));
      for (const { line, dto } of dtos) {
        if (skus.has(dto.sku.toLowerCase())) {
          found.push({
            line,
            message: `Référence « ${dto.sku} » déjà au catalogue`,
          });
        } else if (dto.barcode && codes.has(dto.barcode)) {
          found.push({
            line,
            message: `Code-barres « ${dto.barcode} » déjà utilisé`,
          });
        }
      }
    } else {
      const names = rows.map((r) => ({
        line: r.line,
        name: (r.dto as { name: string }).name,
      }));
      for (const { line, name } of names) {
        inFile(`name:${name.toLowerCase()}`, line, `Nom « ${name} »`);
      }
      const where = {
        name: { in: names.map((n) => n.name), mode: 'insensitive' as const },
      };
      const existing =
        kind === 'customers'
          ? await db.customer.findMany({ where, select: { name: true } })
          : await db.supplier.findMany({ where, select: { name: true } });
      const taken = new Set(existing.map((e) => e.name.toLowerCase()));
      for (const { line, name } of names) {
        if (taken.has(name.toLowerCase())) {
          found.push({ line, message: `« ${name} » existe déjà` });
        }
      }
    }
    return found;
  }

  // ── Lignes ──────────────────────────────────────────────────────────────

  private async productBuilder(
    tiers: { id: string; header: string }[],
  ): Promise<(row: ImportRow) => Promise<Prepared<object> | string>> {
    const [categories, taxRates, locations] = await Promise.all([
      this.prisma.category.findMany({ where: { isActive: true } }),
      this.prisma.taxRate.findMany({ where: { isActive: true } }),
      this.prisma.location.findMany({
        where: { type: { in: ['MAGASIN', 'DEPOT'] }, isActive: true },
      }),
    ]);
    const byName = new Map(categories.map((c) => [c.name.toLowerCase(), c.id]));
    const units = new Map<string, ProductUnitDto>();
    for (const unit of Object.values(ProductUnitDto)) {
      units.set(unit.toLowerCase(), unit);
      units.set(label(unit).toLowerCase(), unit);
    }
    const magasin = locations.find((l) => l.type === 'MAGASIN');
    const depot = locations.find((l) => l.type === 'DEPOT');

    return (row) => {
      const c = row.cells;
      const problems: string[] = [];
      const unit = c['Unité']
        ? units.get(c['Unité'].toLowerCase())
        : ProductUnitDto.PIECE;
      if (!unit) problems.push(`unité « ${c['Unité']} » inconnue`);
      const categoryId = c['Catégorie']
        ? byName.get(c['Catégorie'].toLowerCase())
        : undefined;
      if (c['Catégorie'] && !categoryId) {
        problems.push(`catégorie « ${c['Catégorie']} » inconnue`);
      }
      let taxRateId: string | undefined;
      if (c['TVA %']) {
        const rate = c['TVA %'].replace('%', '').replace(',', '.').trim();
        taxRateId = taxRates.find((t) => Number(t.rate) === Number(rate))?.id;
        if (!taxRateId) problems.push(`taux de TVA « ${c['TVA %']} » inconnu`);
      }
      const quantity = (header: string) => {
        if (!c[header]) return undefined;
        const q = parseImportQuantity(c[header]);
        if (q === null)
          problems.push(`${header} : « ${c[header]} » n’est pas une quantité`);
        return q ?? undefined;
      };
      const minThreshold = quantity('Seuil minimum');
      const initialStock = [
        { location: magasin, quantity: quantity('Stock magasin') },
        { location: depot, quantity: quantity('Stock dépôt') },
      ].flatMap((s) =>
        s.location && s.quantity
          ? [{ locationId: s.location.id, quantity: s.quantity }]
          : [],
      );
      const prices = tiers.flatMap((tier) => {
        if (!c[tier.header]) return [];
        const priceHt = parseMoney(c[tier.header]);
        if (priceHt === null) {
          problems.push(
            `${tier.header} : « ${c[tier.header]} » n’est pas un montant`,
          );
          return [];
        }
        return [{ priceTierId: tier.id, priceHt }];
      });
      if (problems.length > 0) return Promise.resolve(problems.join(' ; '));
      return Promise.resolve({
        line: row.line,
        label: c['Référence'] ?? '',
        dto: {
          sku: c['Référence'],
          name: c['Nom'],
          ...(c['Code-barres'] && { barcode: c['Code-barres'] }),
          unit,
          ...(categoryId && { categoryId }),
          ...(taxRateId && { taxRateId }),
          ...(c['Marque'] && { brand: c['Marque'] }),
          ...(minThreshold && { minThreshold }),
          ...(initialStock.length > 0 && { initialStock }),
        },
        prices,
      });
    };
  }

  private static customerRow(
    row: ImportRow,
  ): Promise<Prepared<object> | string> {
    const c = row.cells;
    let creditLimit: number | undefined;
    if (c['Plafond de crédit']) {
      const amount = parseMoney(c['Plafond de crédit']);
      if (amount === null) {
        return Promise.resolve(
          `Plafond de crédit : « ${c['Plafond de crédit']} » n’est pas un montant`,
        );
      }
      creditLimit = amount;
    }
    return Promise.resolve({
      line: row.line,
      label: c['Nom'] ?? '',
      dto: {
        name: c['Nom'],
        ...(c['Téléphone'] && { phone: c['Téléphone'] }),
        ...(c['E-mail'] && { email: c['E-mail'] }),
        ...(c['Adresse'] && { address: c['Adresse'] }),
        ...(c['Notes'] && { notes: c['Notes'] }),
        ...(creditLimit !== undefined && { creditLimit }),
      },
    });
  }

  private static supplierRow(
    row: ImportRow,
  ): Promise<Prepared<object> | string> {
    const c = row.cells;
    let openingBalance: number | undefined;
    if (c['Reprise de dette']) {
      const amount = parseMoney(c['Reprise de dette']);
      if (amount === null) {
        return Promise.resolve(
          `Reprise de dette : « ${c['Reprise de dette']} » n’est pas un montant`,
        );
      }
      openingBalance = amount;
    }
    return Promise.resolve({
      line: row.line,
      label: c['Nom'] ?? '',
      dto: {
        name: c['Nom'],
        ...(c['Contact'] && { contactName: c['Contact'] }),
        ...(c['Téléphone'] && { phone: c['Téléphone'] }),
        ...(c['E-mail'] && { email: c['E-mail'] }),
        ...(c['Adresse'] && { address: c['Adresse'] }),
        ...(c['Notes'] && { notes: c['Notes'] }),
        ...(openingBalance !== undefined && { openingBalance }),
      },
    });
  }
}
