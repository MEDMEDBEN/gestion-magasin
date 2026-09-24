import { Injectable, OnModuleInit } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { createReadStream } from 'fs';
import { mkdir, rm, writeFile } from 'fs/promises';
import { dirname, join, resolve, sep } from 'path';
import { Readable } from 'stream';

/// Fichiers joints (photos de produits, de signalements) — SEUL point d'accès.
///
/// Stockés sur le DISQUE du serveur, dans un dossier privé : les fichiers ne
/// sortent que par une route authentifiée qui vérifie les droits, jamais par
/// une URL publique.
///
/// Pourquoi pas S3/MinIO : le projet vise UN magasin et UN dépôt. Un serveur
/// d'objets ajoutait un conteneur, des identifiants, un provisionnement de
/// bucket — et le 2026-09-24 les images MinIO ont cessé d'être publiquement
/// téléchargeables, rendant le projet impossible à installer de zéro. Un
/// dossier sauvegardé avec la base fait le même travail, sans dépendance.
/// À reconsidérer seulement si plusieurs serveurs doivent partager les fichiers.
@Injectable()
export class StorageService implements OnModuleInit {
  private readonly root: string;

  constructor(config: ConfigService) {
    // Chemin ABSOLU résolu une fois : tout le reste s'y compare pour interdire
    // qu'une clé malformée écrive ailleurs sur le disque.
    this.root = resolve(config.get<string>('STORAGE_DIR') ?? './var/storage');
  }

  /// Le dossier est créé au démarrage : contrairement à un bucket distant, il
  /// n'y a ni compte de service ni provisionnement séparé à faire échouer.
  async onModuleInit(): Promise<void> {
    await mkdir(this.root, { recursive: true });
  }

  async put(key: string, content: Buffer, contentType: string): Promise<void> {
    const path = this.pathOf(key);
    await mkdir(dirname(path), { recursive: true });
    await writeFile(path, content);
    // Le type est déduit de l'extension à la lecture (`get`) : les clés sont
    // fabriquées par le serveur à partir du format RÉEL des octets, jamais du
    // nom envoyé par le client.
    void contentType;
  }

  async get(key: string): Promise<{ stream: Readable; contentType: string }> {
    const path = this.pathOf(key);
    return {
      stream: createReadStream(path),
      contentType: StorageService.contentTypeOf(key),
    };
  }

  /// Suppression tolérante : un fichier déjà absent n'est pas une erreur.
  async remove(key: string): Promise<void> {
    await rm(this.pathOf(key), { force: true }).catch(() => undefined);
  }

  /// Chemin sur disque d'une clé, BORNÉ au dossier de stockage.
  ///
  /// Les clés viennent du serveur (`products/<id>/<uuid>.jpg`), mais la garde
  /// est ici : une clé contenant `..` ou un chemin absolu écrirait n'importe où
  /// — et cette fonction est le seul endroit par lequel tout passe.
  private pathOf(key: string): string {
    const path = resolve(join(this.root, key));
    if (path !== this.root && !path.startsWith(this.root + sep)) {
      throw new Error(`Clé de stockage hors du dossier autorisé : ${key}`);
    }
    return path;
  }

  private static contentTypeOf(key: string): string {
    const extension = key.slice(key.lastIndexOf('.') + 1).toLowerCase();
    return (
      {
        jpg: 'image/jpeg',
        jpeg: 'image/jpeg',
        png: 'image/png',
        webp: 'image/webp',
      }[extension] ?? 'application/octet-stream'
    );
  }
}
