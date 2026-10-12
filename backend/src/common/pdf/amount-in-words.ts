/// Montant en toutes lettres, en français (mention « Arrêté le présent
/// document à la somme de… » des documents algériens). Calcul en ENTIERS :
/// centimes → dinars et centimes, jamais de flottant (règle 4).

const UNITS = [
  'zéro',
  'un',
  'deux',
  'trois',
  'quatre',
  'cinq',
  'six',
  'sept',
  'huit',
  'neuf',
  'dix',
  'onze',
  'douze',
  'treize',
  'quatorze',
  'quinze',
  'seize',
  'dix-sept',
  'dix-huit',
  'dix-neuf',
];
const TENS = [
  '',
  '',
  'vingt',
  'trente',
  'quarante',
  'cinquante',
  'soixante',
  'soixante',
  'quatre-vingt',
  'quatre-vingt',
];

/// 0..99
function belowHundred(n: number): string {
  if (n < 20) return UNITS[n];
  const ten = Math.floor(n / 10);
  let unit = n % 10;
  // 70-79 et 90-99 : soixante-dix…, quatre-vingt-dix…
  if (ten === 7 || ten === 9) unit += 10;
  if (unit === 0) return ten === 8 ? 'quatre-vingts' : TENS[ten];
  if (unit === 1 && ten !== 8 && ten !== 9) return `${TENS[ten]} et un`;
  if (unit === 11 && ten === 7) return `${TENS[ten]} et onze`;
  return `${TENS[ten]}-${UNITS[unit]}`;
}

/// 0..999 ; `last` : le groupe termine le nombre (« deux cents » ne prend
/// son « s » qu'en fin de nombre — « deux cent mille »).
function belowThousand(n: number, last: boolean): string {
  const hundred = Math.floor(n / 100);
  const rest = n % 100;
  const parts: string[] = [];
  if (hundred === 1) parts.push('cent');
  else if (hundred > 1) {
    parts.push(`${UNITS[hundred]} cent${rest === 0 && last ? 's' : ''}`);
  }
  if (rest > 0) parts.push(belowHundred(rest));
  return parts.join(' ');
}

/// Entier positif en lettres (jusqu'aux milliards).
export function integerInWords(value: number): string {
  if (!Number.isSafeInteger(value) || value < 0) {
    throw new RangeError(`Entier positif attendu : ${value}`);
  }
  if (value === 0) return 'zéro';
  const groups: [number, string, string][] = [
    [1_000_000_000, 'milliard', 'milliards'],
    [1_000_000, 'million', 'millions'],
    [1_000, 'mille', 'mille'],
  ];
  const parts: string[] = [];
  let rest = value;
  for (const [size, one, many] of groups) {
    const count = Math.floor(rest / size);
    rest %= size;
    if (count === 0) continue;
    if (size === 1_000) {
      // « mille », jamais « un mille » ; « deux mille », invariable.
      parts.push(
        count === 1 ? 'mille' : `${belowThousand(count, false)} mille`,
      );
    } else {
      parts.push(`${belowThousand(count, true)} ${count > 1 ? many : one}`);
    }
  }
  if (rest > 0) parts.push(belowThousand(rest, true));
  return parts.join(' ');
}

/// Centimes → « mille deux cent cinquante dinars et cinquante centimes ».
export function amountInWords(centimes: number): string {
  const negative = centimes < 0;
  const abs = Math.abs(centimes);
  const dinars = Math.trunc(abs / 100);
  const cents = abs % 100;
  const text =
    `${integerInWords(dinars)} dinar${dinars > 1 ? 's' : ''}` +
    (cents > 0
      ? ` et ${integerInWords(cents)} centime${cents > 1 ? 's' : ''}`
      : '');
  return `${negative ? 'moins ' : ''}${text}`;
}
