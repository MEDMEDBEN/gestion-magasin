import { parse } from 'dotenv';
import { existsSync, readFileSync } from 'fs';
import { join } from 'path';

/// Base DÉDIÉE aux tests d'intégration — jamais la base de dev (CONVENTIONS.md,
/// règle 5) : les e2e écrivent, verrouillent et nettoient ; ils ne doivent ni
/// polluer les données de développement ni dépendre de leur état.
///
/// `TEST_DATABASE_URL` si fourni (CI), sinon l'URL de dev de `backend/.env` avec
/// le nom de base suffixé `_test` (`gestion_magasin_dev` → `gestion_magasin_dev_test`).
export function testDatabaseUrl(): string {
  const explicit = process.env.TEST_DATABASE_URL;
  const envFile = join(__dirname, '..', '.env');
  const dev =
    process.env.DATABASE_URL ??
    (existsSync(envFile)
      ? parse(readFileSync(envFile)).DATABASE_URL
      : undefined);
  const raw = explicit ?? dev;
  if (!raw) {
    throw new Error(
      'Aucune base pour les tests : définir TEST_DATABASE_URL ou DATABASE_URL.',
    );
  }
  const url = new URL(raw);
  const name = url.pathname.replace(/^\//, '');
  if (!explicit && !name.endsWith('_test')) {
    url.pathname = `/${name}_test`;
  }
  if (!url.pathname.endsWith('_test')) {
    throw new Error(
      `Refus : la base de test doit se terminer par « _test » (reçu « ${url.pathname} »).`,
    );
  }
  return url.toString();
}
