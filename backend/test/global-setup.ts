import { execSync } from 'child_process';
import { join } from 'path';
import { Client } from 'pg';
import { testDatabaseUrl } from './test-database';

/// Prépare la base de test UNE fois avant toute la suite : création si absente,
/// migrations, données de référence (seed idempotent). Chaque lancement repart
/// donc d'un schéma à jour, sans jamais toucher la base de dev.
export default async function globalSetup(): Promise<void> {
  const url = testDatabaseUrl();
  const target = new URL(url);
  const database = target.pathname.replace(/^\//, '');

  const admin = new URL(url);
  admin.pathname = '/postgres';
  admin.search = '';
  const client = new Client({ connectionString: admin.toString() });
  await client.connect();
  try {
    const exists = await client.query(
      'SELECT 1 FROM pg_database WHERE datname = $1',
      [database],
    );
    if (exists.rowCount === 0) {
      // Nom validé par testDatabaseUrl (suffixe _test) ; identifiant cité.
      await client.query(`CREATE DATABASE "${database.replace(/"/g, '""')}"`);
    }
  } finally {
    await client.end();
  }

  const env = { ...process.env, DATABASE_URL: url };
  const cwd = join(__dirname, '..');
  execSync('npx prisma migrate deploy', { cwd, env, stdio: 'ignore' });
  execSync('npm run seed', { cwd, env, stdio: 'ignore' });
}
