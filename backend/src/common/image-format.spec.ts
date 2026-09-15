import { detectImageFormat } from './image-format';

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
