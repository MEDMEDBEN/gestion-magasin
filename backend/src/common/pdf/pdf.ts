import * as PDFDocument from 'pdfkit';

export type PdfDoc = PDFKit.PDFDocument;

/// Moteur PDF UNIQUE du projet (CONVENTIONS.md) : pdfkit, polices standard
/// (Helvetica, jeu WinAnsi : accents français OK) — rien à embarquer dans
/// l'image Docker. Tout document PDF passe par ici.
export function renderPdf(
  options: PDFKit.PDFDocumentOptions,
  draw: (doc: PdfDoc) => void,
): Promise<Buffer> {
  return new Promise((resolve, reject) => {
    const doc = new PDFDocument(options);
    const chunks: Buffer[] = [];
    doc.on('data', (chunk: Buffer) => chunks.push(chunk));
    doc.on('end', () => resolve(Buffer.concat(chunks)));
    doc.on('error', reject);
    try {
      draw(doc);
      doc.end();
    } catch (error) {
      reject(error instanceof Error ? error : new Error(String(error)));
    }
  });
}

/// Centimes → « 1 725,50 DA » (espace simple : sûr pour les polices standard).
export function formatDA(centimes: number): string {
  const sign = centimes < 0 ? '-' : '';
  const abs = Math.abs(centimes);
  const units = Math.trunc(abs / 100)
    .toString()
    .replace(/\B(?=(\d{3})+(?!\d))/g, ' ');
  return `${sign}${units},${(abs % 100).toString().padStart(2, '0')} DA`;
}

/// Date et heure en Algérie (Africa/Algiers), « 15/09/2026 14:05 ».
export function formatDateTime(date: Date): string {
  return new Intl.DateTimeFormat('fr-FR', {
    timeZone: 'Africa/Algiers',
    dateStyle: 'short',
    timeStyle: 'short',
  })
    .format(date)
    .replace(',', '');
}
