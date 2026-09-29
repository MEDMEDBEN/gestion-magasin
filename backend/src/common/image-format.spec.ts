import { detectImageFormat, imageDimensions } from './image-format';

describe('detectImageFormat', () => {
  it('reconnaît JPEG, PNG et WebP par leur signature', () => {
    expect(
      detectImageFormat(Buffer.from([0xff, 0xd8, 0xff, 0xe0]))?.extension,
    ).toBe('jpg');
    const png = Buffer.from([
      0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0,
    ]);
    expect(detectImageFormat(png)?.contentType).toBe('image/png');
    const webp = Buffer.concat([
      Buffer.from('RIFF'),
      Buffer.alloc(4),
      Buffer.from('WEBPVP8 '),
    ]);
    expect(detectImageFormat(webp)?.extension).toBe('webp');
  });

  it('refuse tout le reste (script, SVG, PDF, fichier vide)', () => {
    for (const content of [
      '<svg onload=alert(1)>',
      '%PDF-1.7',
      '#!/bin/sh',
      '',
    ]) {
      expect(detectImageFormat(Buffer.from(content))).toBeNull();
    }
  });
});

describe('dimensions d’une image lues dans l’en-tête', () => {
  it('PNG : IHDR', () => {
    const png = Buffer.alloc(24);
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]).copy(png);
    png.write('IHDR', 12, 'ascii');
    png.writeUInt32BE(20000, 16);
    png.writeUInt32BE(20000, 20);
    expect(imageDimensions(png)).toEqual({ width: 20000, height: 20000 });
  });

  it('JPEG : segment SOF après un APP0', () => {
    const jpeg = Buffer.from([
      0xff, 0xd8, 0xff, 0xe0, 0x00, 0x04, 0x00, 0x00, 0xff, 0xc0, 0x00, 0x11,
      0x08, 0x04, 0x38, 0x07, 0x80, 0x03,
    ]);
    expect(imageDimensions(jpeg)).toEqual({ width: 1920, height: 1080 });
  });

  it('en-tête illisible : null', () => {
    expect(imageDimensions(Buffer.from('pas une image'))).toBeNull();
  });
});
