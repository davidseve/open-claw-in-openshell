/**
 * Load secrets/secrets.env into process.env for local Playwright runs.
 * Does not override variables already set in the environment.
 * Cluster URLs are still resolved by scripts/run-playwright-tests.sh when
 * using cluster-lifecycle.sh.
 */
import * as fs from 'fs';
import * as path from 'path';

export function loadLocalSecretsEnv(secretsPath?: string): void {
  const file =
    secretsPath ?? path.join(__dirname, '..', 'secrets', 'secrets.env');
  if (!fs.existsSync(file)) return;

  for (const line of fs.readFileSync(file, 'utf8').split('\n')) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;
    const eq = trimmed.indexOf('=');
    if (eq <= 0) continue;

    const key = trimmed.slice(0, eq).trim();
    let value = trimmed.slice(eq + 1).trim();
    if (
      (value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1);
    }
    if (!process.env[key]) {
      process.env[key] = value;
    }
  }
}
