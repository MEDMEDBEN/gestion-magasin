import { HttpStatus, Injectable } from '@nestjs/common';
import { plainToInstance } from 'class-transformer';
import { validate, ValidationError } from 'class-validator';
import { ActorContext } from '../audit/audit-writer';
import { normalizeBarcode } from '../common/barcode/barcode';
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
  ImportTable,
  normalize,
  parseImportQuantity,
  parseMoney,
  readTable,
} from '../common/export/import';
import { CreateCustomerDto } from '../customers/dto/customer.dto';
import { CustomersService } from '../customers/customers.service';
import { Prisma } from '../generated/prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import {
  CreateProductDto,
  ProductUnitDto,
  SetProductPriceDto,
} from '../products/dto/product.dto';
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

/// Champ du DTO → en-tête du fichier : l'erreur nomme la colonne à corriger.
const FIELD_HEADER: Record<string, string> = {
  sku: 'Référence',
  name: 'Nom',
  barcode: 'Code-barres',
  unit: 'Unité',
  brand: 'Marque',
  minThreshold: 'Seuil minimum',
  initialStock: 'Stock initial',
  phone: 'Téléphone',
  email: 'E-mail',
  address: 'Adresse',
  notes: 'Notes',
  creditLimit: 'Plafond de crédit',
  contactName: 'Contact',
  openingBalance: 'Reprise de dette',
};

const CONSTRAINT_TEXT: Record<string, string> = {
  isNotEmpty: 'obligatoire',
  minLength: 'trop court',
  maxLength: 'trop long',
  max: 'trop grand',
  min: 'ne peut pas être négatif',
  isEmail: 'adresse e-mail invalide',
};

/// Refus de validation → « Nom : trop court », dans la langue de l'écran.
function frenchErrors(errors: ValidationError[], field?: string): string[] {
  return errors.flatMap((error) => {
    const header = field ?? FIELD_HEADER[error.property] ?? error.property;
    const own = Object.entries(error.constraints ?? {}).map(
      ([kind, message]) => `${header} : ${CONSTRAINT_TEXT[kind] ?? message}`,
    );
    return [...own, ...frenchErrors(error.children ?? [], header)];
  });
}

const VALIDATION = { whitelist: true, forbidNonWhitelisted: true };

interface Prepared<Dto> {
  line: number;
  label: string;
  dto: Dto;
  prices?: { priceTierId: string; priceHt: number }[];
  /// En-tête de chaque prix, pour nommer la colonne fautive.
  priceHeaders?: string[];
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
      customers: async () =>
        ImportsService.templateDocument(
          'Import clients',
          ImportsService.CUSTOMER_HEADERS,
          {
            Nom: 'Électricité Benali',
            Téléphone: '0550 12 34 56',
            'Plafond de crédit': '50000,00',
          },
        ),
      suppliers: async () =>
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
      total: prepared.total,
      created,
      errors,
      ignored: prepared.ignored,
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
            // Son code et son statut d'origine sont gardés (409 reste 409).
            if (error instanceof BusinessException) {
              const { code, message } = error.getResponse() as {
                code: ErrorCode;
                message?: string;
              };
              throw new BusinessException(
                code,
                `Ligne ${row.line} (${row.label}) : ${message} — rien n’a été créé`,
                error.getStatus(),
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

    let table: ImportTable;
    let build: (row: ImportRow) => Prepared<object> | string;
    if (kind === 'products') {
      const columns = await this.productColumns();
      table = await readTable(file, columns.headers, columns.required);
      build = await this.productBuilder(columns.tiers);
    } else if (kind === 'customers') {
      table = await readTable(file, ImportsService.CUSTOMER_HEADERS, ['Nom']);
      build = ImportsService.customerRow;
    } else {
      table = await readTable(file, ImportsService.SUPPLIER_HEADERS, ['Nom']);
      build = ImportsService.supplierRow;
    }
    const dtoClass: new () => object =
      kind === 'products'
        ? CreateProductDto
        : kind === 'customers'
          ? CreateCustomerDto
          : CreateSupplierDto;

    for (const row of table.rows) {
      if (row.error) {
        fail(row.line, row.error);
        continue;
      }
      const built = build(row);
      if (typeof built === 'string') {
        fail(row.line, built);
        continue;
      }
      // L'instance VALIDÉE est gardée : c'est elle, nettoyée par les
      // `@Transform` du DTO (espaces retirés…), qui sera créée.
      const dto = plainToInstance(dtoClass, built.dto);
      const invalid = frenchErrors(await validate(dto, VALIDATION));
      for (const [i, price] of (built.prices ?? []).entries()) {
        const checked = plainToInstance(SetProductPriceDto, price);
        invalid.push(
          ...frenchErrors(
            await validate(checked, VALIDATION),
            built.priceHeaders?.[i],
          ),
        );
      }
      if (invalid.length > 0) {
        fail(row.line, invalid.join(' ; '));
        continue;
      }
      rows.push({ ...built, dto });
    }
    for (const duplicate of await this.duplicates(this.prisma, kind, rows)) {
      fail(duplicate.line, duplicate.message);
    }
    errors.sort((a, b) => a.line - b.line);
    const bad = new Set(errors.map((e) => e.line));
    return {
      rows: rows.filter((r) => !bad.has(r.line)),
      errors,
      total: table.rows.length,
      ignored: table.ignored,
    };
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
        inFile(`name:${normalize(name)}`, line, `Nom « ${name} »`);
      }
      // Comparaison sans accents ni casse : faite ici, sur tous les noms.
      // ponytail : quelques milliers de fiches au plus pour un magasin ; une
      // colonne normalisée indexée si la base grossit.
      const existing =
        kind === 'customers'
          ? await db.customer.findMany({ select: { name: true } })
          : await db.supplier.findMany({ select: { name: true } });
      const taken = new Set(existing.map((e) => normalize(e.name)));
      for (const { line, name } of names) {
        if (taken.has(normalize(name))) {
          found.push({ line, message: `« ${name} » existe déjà` });
        }
      }
    }
    return found;
  }

  // ── Lignes ──────────────────────────────────────────────────────────────

  private async productBuilder(
    tiers: { id: string; header: string }[],
  ): Promise<(row: ImportRow) => Prepared<object> | string> {
    const [categories, taxRates, locations] = await Promise.all([
      this.prisma.category.findMany({ where: { isActive: true } }),
      this.prisma.taxRate.findMany({ where: { isActive: true } }),
      this.prisma.location.findMany({
        where: { type: { in: ['MAGASIN', 'DEPOT'] }, isActive: true },
      }),
    ]);
    const byName = new Map(categories.map((c) => [normalize(c.name), c.id]));
    const units = new Map<string, ProductUnitDto>();
    for (const unit of Object.values(ProductUnitDto)) {
      units.set(normalize(unit), unit);
      units.set(normalize(label(unit)), unit);
    }
    const magasin = locations.find((l) => l.type === 'MAGASIN');
    const depot = locations.find((l) => l.type === 'DEPOT');

    return (row) => {
      const c = row.cells;
      const problems: string[] = [];
      const unit = c['Unité']
        ? units.get(normalize(c['Unité']))
        : ProductUnitDto.PIECE;
      if (!unit) problems.push(`unité « ${c['Unité']} » inconnue`);
      const categoryId = c['Catégorie']
        ? byName.get(normalize(c['Catégorie']))
        : undefined;
      if (c['Catégorie'] && !categoryId) {
        problems.push(`catégorie « ${c['Catégorie']} » inconnue`);
      }
      let taxRateId: string | undefined;
      if (c['TVA %']) {
        const text = c['TVA %'].replace('%', '').replace(',', '.').trim();
        // Une cellule Excel au format « % » vaut 0,19 pour 19 %.
        const rate =
          Number(text) > 0 && Number(text) < 1
            ? Math.round(Number(text) * 10_000) / 100
            : Number(text);
        taxRateId = text
          ? taxRates.find((t) => Number(t.rate) === rate)?.id
          : undefined;
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
        { header: 'Stock magasin', location: magasin },
        { header: 'Stock dépôt', location: depot },
      ].flatMap(({ header, location }) => {
        const q = quantity(header);
        if (!q) return [];
        if (!location) {
          problems.push(`${header} : aucun emplacement actif de ce type`);
          return [];
        }
        return [{ locationId: location.id, quantity: q }];
      });
      // Même normalisation que la création unitaire, dès la vérification à
      // blanc : un code illisible est signalé AVANT l'import, pas pendant.
      let barcode: string | undefined;
      if (c['Code-barres']) {
        try {
          barcode = normalizeBarcode(c['Code-barres']);
        } catch (error) {
          if (!(error instanceof BusinessException)) throw error;
          const { message } = error.getResponse() as { message?: string };
          problems.push(message ?? 'Code-barres invalide');
        }
      }
      const priced = tiers.flatMap((tier) => {
        if (!c[tier.header]) return [];
        const priceHt = parseMoney(c[tier.header]);
        if (priceHt === null) {
          problems.push(
            `${tier.header} : « ${c[tier.header]} » n’est pas un montant`,
          );
          return [];
        }
        return [
          { header: tier.header, price: { priceTierId: tier.id, priceHt } },
        ];
      });
      if (problems.length > 0) return problems.join(' ; ');
      return {
        line: row.line,
        label: c['Référence'] ?? '',
        dto: {
          sku: c['Référence'],
          name: c['Nom'],
          ...(barcode && { barcode }),
          unit,
          ...(categoryId && { categoryId }),
          ...(taxRateId && { taxRateId }),
          ...(c['Marque'] && { brand: c['Marque'] }),
          ...(minThreshold && { minThreshold }),
          ...(initialStock.length > 0 && { initialStock }),
        },
        prices: priced.map((p) => p.price),
        priceHeaders: priced.map((p) => p.header),
      };
    };
  }

  private static customerRow(
    this: void,
    row: ImportRow,
  ): Prepared<object> | string {
    const c = row.cells;
    let creditLimit: number | undefined;
    if (c['Plafond de crédit']) {
      const amount = parseMoney(c['Plafond de crédit']);
      if (amount === null) {
        return `Plafond de crédit : « ${c['Plafond de crédit']} » n’est pas un montant`;
      }
      creditLimit = amount;
    }
    return {
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
    };
  }

  private static supplierRow(
    this: void,
    row: ImportRow,
  ): Prepared<object> | string {
    const c = row.cells;
    let openingBalance: number | undefined;
    if (c['Reprise de dette']) {
      const amount = parseMoney(c['Reprise de dette']);
      if (amount === null) {
        return `Reprise de dette : « ${c['Reprise de dette']} » n’est pas un montant`;
      }
      openingBalance = amount;
    }
    return {
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
    };
  }
}
