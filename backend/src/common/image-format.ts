/// Formats de photo acceptés, reconnus à leur SIGNATURE binaire : un fichier
/// renommé en .jpg ou un en-tête `Content-Type` menteur ne passe pas.
export interface ImageFormat {
  extension: 'jpg' | 'png' | 'webp';
  contentType: 'image/jpeg' | 'image/png' | 'image/webp';
}

const PNG_SIGNATURE = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];

export function detectImageFormat(bytes: Buffer): ImageFormat | null {
  if (
    bytes.length >= 3 &&
    bytes[0] === 0xff &&
    bytes[1] === 0xd8 &&
    bytes[2] === 0xff
  ) {
    return { extension: 'jpg', contentType: 'image/jpeg' };
  }
  if (bytes.length >= 8 && PNG_SIGNATURE.every((b, i) => bytes[i] === b)) {
    return { extension: 'png', contentType: 'image/png' };
  }
  if (
    bytes.length >= 12 &&
    bytes.toString('ascii', 0, 4) === 'RIFF' &&
    bytes.toString('ascii', 8, 12) === 'WEBP'
  ) {
    return { extension: 'webp', contentType: 'image/webp' };
  }
  return null;
}
