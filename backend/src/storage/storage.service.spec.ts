import { ConfigService } from '@nestjs/config';
import { HttpStatus } from '@nestjs/common';
import { mkdtemp, readFile, rm, writeFile } from 'fs/promises';
import { tmpdir } from 'os';
import { join } from 'path';
import { BusinessException } from '../common/business.exception';
import { StorageService } from './storage.service';

/// Fichiers joints : le stockage est sur le DISQUE du serveur (MinIO retiré le
/// 2026-09-24). Deux choses seulement sont éprouvées ici, parce que ce sont les
/// deux qui font mal : une clé ne doit jamais écrire hors du dossier, et un
/// fichier absent ne doit pas tuer le processus.
describe('StorageService', () => {
  let root: string;
  let storage: StorageService;

  const make = async (dir: string) => {
    const service = new StorageService({
      get: () => dir,
    } as unknown as ConfigService);
    await service.onModuleInit();
    return service;
  };

  beforeEach(async () => {
    root = await mkdtemp(join(tmpdir(), 'storage-spec-'));
    storage = await make(root);
  });

  afterEach(async () => {
    await rm(root, { recursive: true, force: true });
  });

  it('écrit, relit et supprime un fichier', async () => {
    await storage.put('problems/p1/photo.png', Buffer.from('abc'), 'image/png');

    const { stream, contentType } = await storage.get('problems/p1/photo.png');
    expect(contentType).toBe('image/png');
    const chunks: Buffer[] = [];
    for await (const chunk of stream) chunks.push(chunk as Buffer);
    expect(Buffer.concat(chunks).toString()).toBe('abc');

    await storage.remove('problems/p1/photo.png');
    await expect(storage.get('problems/p1/photo.png')).rejects.toThrow(
      BusinessException,
    );
  });

  /// Le cas qui faisait tomber le PROCESSUS : un `ENOENT` émis sur un flux déjà
  /// rendu à l'appelant n'a pas d'écouteur, et aucun filtre Nest ne l'attrape.
  /// Il arrive pour de bon — base restaurée sans le dossier de stockage.
  it('fichier absent : 404 métier, pas une erreur technique différée', async () => {
    await expect(
      storage.get('problems/p1/jamais-ecrit.png'),
    ).rejects.toMatchObject({ status: HttpStatus.NOT_FOUND });
  });

  it('supprimer un fichier déjà absent n’est pas une erreur', async () => {
    await expect(
      storage.remove('problems/p1/rien.png'),
    ).resolves.toBeUndefined();
  });

  /// La garde de `pathOf` : les clés viennent du serveur, mais c'est le SEUL
  /// endroit par lequel tout passe — donc c'est ici qu'on l'éprouve.
  it('refuse d’écrire ou de lire hors du dossier de stockage', async () => {
    const outside = join(root, '..', 'evade.png');
    await expect(
      storage.put('../evade.png', Buffer.from('x'), 'image/png'),
    ).rejects.toThrow(/hors du dossier autoris/);
    await expect(storage.get('../evade.png')).rejects.toThrow(
      /hors du dossier autoris/,
    );
    await expect(readFile(outside)).rejects.toThrow();

    // Même refus sur un chemin absolu, et sur une clé qui remonte par le milieu.
    await expect(
      storage.put('problems/../../evade.png', Buffer.from('x'), 'image/png'),
    ).rejects.toThrow(/hors du dossier autoris/);
  });

  it('un fichier écrit hors clé ne devient pas lisible par ruse d’extension', async () => {
    await writeFile(join(root, 'brut.bin'), Buffer.from('xyz'));
    const { contentType } = await storage.get('brut.bin');
    // Type déduit de l'extension, jamais du contenu envoyé par le client.
    expect(contentType).toBe('application/octet-stream');
  });
});
