import { Injectable, OnModuleInit } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { Client } from 'minio';
import { Readable } from 'stream';

/// Stockage de fichiers S3-compatible (MinIO) — SEUL point d'accès aux objets.
/// Le bucket est PRIVÉ : les fichiers ne sortent que par une route authentifiée
/// qui vérifie les droits, jamais par une URL publique.
@Injectable()
export class StorageService implements OnModuleInit {
  private readonly client: Client;
  private readonly bucket: string;

  constructor(config: ConfigService) {
    this.client = new Client({
      endPoint: config.getOrThrow<string>('MINIO_ENDPOINT'),
      port: Number(config.get('MINIO_PORT') ?? 9000),
      useSSL: config.get('MINIO_USE_SSL') === 'true',
      accessKey: config.getOrThrow<string>('MINIO_ACCESS_KEY'),
      secretKey: config.getOrThrow<string>('MINIO_SECRET_KEY'),
    });
    this.bucket = config.getOrThrow<string>('MINIO_BUCKET');
  }

  async onModuleInit(): Promise<void> {
    if (!(await this.client.bucketExists(this.bucket))) {
      await this.client.makeBucket(this.bucket);
    }
  }

  async put(key: string, content: Buffer, contentType: string): Promise<void> {
    await this.client.putObject(this.bucket, key, content, content.length, {
      'Content-Type': contentType,
    });
  }

  async get(key: string): Promise<{ stream: Readable; contentType: string }> {
    const [stat, stream] = await Promise.all([
      this.client.statObject(this.bucket, key),
      this.client.getObject(this.bucket, key),
    ]);
    return {
      stream,
      contentType:
        (stat.metaData?.['content-type'] as string | undefined) ??
        'application/octet-stream',
    };
  }

  /// Suppression tolérante : un objet déjà absent n'est pas une erreur.
  async remove(key: string): Promise<void> {
    await this.client.removeObject(this.bucket, key).catch(() => undefined);
  }
}
