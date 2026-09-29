import {
  HttpStatus,
  Injectable,
  Logger,
  OnModuleDestroy,
} from '@nestjs/common';
import { ApiProperty } from '@nestjs/swagger';
import { dirname, join } from 'path';
import { createWorker, Worker } from 'tesseract.js';
import { BusinessException } from '../common/business.exception';
import { ErrorCode } from '../common/error-codes';
import { detectImageFormat, imageDimensions } from '../common/image-format';
import { PrismaService } from '../prisma/prisma.service';

/// Lecture d'une facture fournisseur (P2 n°24, spec §28) : une PHOTO devient
/// des lignes PROPOSÉES (produit reconnu, quantité, prix unitaire HT). Ce n'est
/// JAMAIS une source de vérité : l'app pré-remplit un formulaire que
/// l'utilisateur corrige avant de valider, par le chemin habituel (commande,
/// réception) et ses contrôles. Rien n'est écrit ici.

export class InvoiceScanLineDto {
  @ApiProperty({ description: 'Ligne telle que lue sur la facture.' })
  text!: string;
  @ApiProperty({ nullable: true }) productId!: string | null;
  @ApiProperty({ nullable: true }) productName!: string | null;
  @ApiProperty({ nullable: true, example: '10.000' })
  quantity!: string | null;
  @ApiProperty({
    nullable: true,
    description: 'Prix unitaire HT lu, en centimes.',
  })
  unitPriceHt!: number | null;
}

export class InvoiceScanDto {
  @ApiProperty({ type: [InvoiceScanLineDto] })
  lines!: InvoiceScanLineDto[];
  @ApiProperty({ description: 'Texte brut lu (pour vérification).' })
  text!: string;
}

export interface ScanProduct {
  id: string;
  name: string;
  sku: string;
  barcode: string;
}

/// Au-delà, une image est refusée AVANT l'OCR (« bombe » de décompression) :
/// l'app envoie au plus 2 200 px de côté, soit ~5 Mpx.
export const MAX_SCAN_PIXELS = 25_000_000;
/// Une lecture qui dépasse ce délai est abandonnée et le moteur recréé.
const SCAN_TIMEOUT_MS = 60_000;

/// « Électricité » → « electricite » : comparaison sans accents ni casse.
function fold(value: string): string {
  return value.normalize('NFD').replace(/\p{M}/gu, '').toLowerCase();
}

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

/// `part` présent comme MOT(S) ENTIER(S) dans `text` (déjà repliés) : « vis »
/// n'est pas dans « devis », « fil » n'est pas dans « profil ».
function wordPattern(part: string): RegExp {
  return new RegExp(
    `(^|[^\\p{L}\\p{N}])${escapeRegExp(part)}(?=$|[^\\p{L}\\p{N}])`,
    'gu',
  );
}

function toNumber(token: string): number {
  // « 1.200,50 » : le point sépare les milliers, la virgule les décimales.
  return Number(
    token.includes(',') ? token.replace(/\./g, '').replace(',', '.') : token,
  );
}

/// Lectures possibles des nombres d'une ligne au format français. L'espace
/// est ambigu : « 1 200,00 » est UN nombre (millier), mais « 5 350,00 » peut
/// être la quantité 5 suivie du prix 350,00. On énumère donc les découpages
/// (un groupe de 3 chiffres PEUT prolonger le nombre qui le précède), le plus
/// fusionné d'abord ; `readInvoiceLines` garde celui que le total confirme.
export function numberReadings(line: string): number[][] {
  const words = line.split(' ');
  const tokens: { value: string; index: number }[] = [];
  words.forEach((word, index) => {
    if (/^\d+(?:[.,]\d+)*$/.test(word)) tokens.push({ value: word, index });
  });
  const readings: number[][] = [];
  const walk = (i: number, groups: string[], lastIndex: number) => {
    if (readings.length >= 64) return;
    if (i === tokens.length) {
      readings.push(groups.map(toNumber).filter((n) => Number.isFinite(n)));
      return;
    }
    const { value, index } = tokens[i];
    const previous = groups[groups.length - 1];
    if (
      previous !== undefined &&
      index === lastIndex + 1 &&
      !previous.includes(',') &&
      /^\d+$/.test(previous) &&
      /^\d{3}(?:,\d+)?$/.test(value)
    ) {
      walk(i + 1, [...groups.slice(0, -1), previous + value], index);
    }
    walk(i + 1, [...groups, value], index);
  };
  walk(0, [], -2);
  return readings.length > 0 ? readings : [[]];
}

/// Premier découpage (le plus fusionné) — pour les tests et les lignes sans
/// total vérifiable.
export function numbersOf(line: string): number[] {
  return numberReadings(line)[0];
}

/// Quantité et prix d'une lecture : « q prix total » confirmé par
/// q × prix ≈ total.
function confirmed(numbers: number[]): [number, number] | null {
  if (numbers.length < 3) return null;
  const [q, u, t] = numbers.slice(-3);
  return q > 0 && Math.abs(q * u - t) <= Math.max(1, t * 0.01) ? [q, u] : null;
}

/// Lignes proposées à partir du texte lu. Un produit est reconnu par son
/// code-barres (≥ 6) ou sa référence (≥ 3) comme mot exact, sinon par son NOM
/// présent en mots entiers (le plus long gagne). Quantité et prix : les
/// nombres qui RESTENT une fois retirés le code, la référence et le nom ; le
/// découpage que le total confirme gagne, sinon « q prix » parmi les derniers.
export function readInvoiceLines(
  text: string,
  products: ScanProduct[],
): InvoiceScanLineDto[] {
  const byName = [...products]
    .filter((p) => fold(p.name).trim().length >= 3)
    .sort((a, b) => b.name.length - a.name.length);
  const lines: InvoiceScanLineDto[] = [];
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.replace(/\s+/g, ' ').trim();
    if (line.length < 3) continue;
    const folded = fold(line);
    const words = new Set(folded.split(' '));
    const codes = (p: ScanProduct) =>
      [
        p.barcode.length >= 6 ? fold(p.barcode) : null,
        p.sku.length >= 3 ? fold(p.sku) : null,
      ].filter((c): c is string => c !== null);
    let product =
      products.find((p) => codes(p).some((c) => words.has(c))) ?? null;
    if (!product) {
      product =
        byName.find((p) => wordPattern(fold(p.name)).test(folded)) ?? null;
    }
    // Les chiffres du code, de la référence et du nom ne sont pas des
    // quantités (« Disjoncteur 16A », « 2,5 mm² ») — retirés en mots entiers.
    let rest = folded;
    if (product) {
      for (const part of [...codes(product), fold(product.name)]) {
        rest = rest.replace(wordPattern(part), '$1 ');
      }
    }
    rest = rest.replace(/\s+/g, ' ').trim();
    const readings = numberReadings(rest);
    const count = Math.max(...readings.map((r) => r.length));
    if (!product && count < 2) continue;

    let quantity: number | null = null;
    let unit: number | null = null;
    const sure = readings.map(confirmed).find((pair) => pair !== null);
    if (sure) {
      [quantity, unit] = sure;
    } else {
      const numbers = readings[0];
      if (numbers.length >= 2) {
        // Sans total vérifiable : les deux premiers des trois derniers (les
        // chiffres de la désignation viennent en tête de ligne).
        const tail = numbers.slice(-3);
        [quantity, unit] = [tail[0], tail[1]];
      } else if (numbers.length === 1) {
        quantity = numbers[0];
      }
    }
    lines.push({
      text: line,
      productId: product?.id ?? null,
      productName: product?.name ?? null,
      quantity:
        quantity !== null && quantity > 0 && quantity < 1_000_000
          ? quantity.toFixed(3)
          : null,
      unitPriceHt:
        unit !== null && unit >= 0 && unit < 100_000_000
          ? Math.round(unit * 100)
          : null,
    });
  }
  return lines;
}

/// Moteur OCR : Tesseract, modèle FRANÇAIS livré avec le serveur (paquet
/// `@tesseract.js-data/fra`) — aucun téléchargement, fonctionne hors Internet.
/// Un seul moteur, créé au premier scan et gardé : l'initialiser coûte
/// plusieurs secondes. Il traite les images l'une après l'autre.
///
/// ISOLÉ du reste du serveur : `errorHandler` empêche tesseract.js de relancer
/// une erreur de lecture dans son écouteur (elle tuerait le processus entier —
/// audit sécurité n°24) ; une lecture trop longue ou en échec jette le moteur,
/// le suivant est neuf.
@Injectable()
export class InvoiceScanService implements OnModuleDestroy {
  private readonly logger = new Logger(InvoiceScanService.name);
  private worker: Promise<Worker> | null = null;

  constructor(private readonly prisma: PrismaService) {}

  private engine(): Promise<Worker> {
    this.worker ??= createWorker('fra', 1, {
      langPath: join(
        dirname(require.resolve('@tesseract.js-data/fra/package.json')),
        '4.0.0_best_int',
      ),
      cacheMethod: 'none',
      gzip: true,
      errorHandler: (error: unknown) =>
        this.logger.warn(`OCR : ${String(error)}`),
    }).catch((error: unknown) => {
      this.worker = null;
      throw error;
    });
    return this.worker;
  }

  /// Jette le moteur courant (après une erreur ou un délai dépassé).
  private discard(): void {
    const dead = this.worker;
    this.worker = null;
    void dead?.then((w) => w.terminate()).catch(() => undefined);
  }

  async onModuleDestroy(): Promise<void> {
    if (this.worker) await (await this.worker).terminate();
  }

  async scan(file: Express.Multer.File | undefined): Promise<InvoiceScanDto> {
    const format = file && detectImageFormat(file.buffer);
    const size = file && imageDimensions(file.buffer);
    if (
      !file ||
      !format ||
      format.contentType === 'image/webp' ||
      !size ||
      size.width * size.height > MAX_SCAN_PIXELS
    ) {
      throw new BusinessException(
        ErrorCode.VALIDATION_FAILED,
        'image : photo JPEG ou PNG de la facture attendue (25 millions de pixels au plus)',
        HttpStatus.UNPROCESSABLE_ENTITY,
      );
    }
    let text: string;
    let timer: NodeJS.Timeout | undefined;
    try {
      const reading = (await this.engine()).recognize(file.buffer);
      const timeout = new Promise<never>((_, reject) => {
        timer = setTimeout(
          () => reject(new Error('délai de lecture dépassé')),
          SCAN_TIMEOUT_MS,
        );
      });
      text = (await Promise.race([reading, timeout])).data.text;
    } catch (error) {
      this.logger.error(`Lecture de facture impossible : ${String(error)}`);
      this.discard();
      throw new BusinessException(
        ErrorCode.VALIDATION_FAILED,
        'La facture n’a pas pu être lue : reprenez la photo (bien à plat, nette, éclairée)',
        HttpStatus.UNPROCESSABLE_ENTITY,
      );
    } finally {
      clearTimeout(timer);
    }
    // ponytail: catalogue actif lu en mémoire (quelques milliers de produits).
    const products = await this.prisma.product.findMany({
      where: { isActive: true },
      select: { id: true, name: true, sku: true, barcode: true },
    });
    return { lines: readInvoiceLines(text, products), text };
  }
}
