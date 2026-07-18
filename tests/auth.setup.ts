import { test as setup, expect } from '@playwright/test';
import * as fs from 'fs';
import * as path from 'path';

const STORAGE_STATE = path.join(__dirname, 'test-results', '.auth', 'state.json');

setup('authenticate via Keycloak', async ({ page }) => {
  fs.mkdirSync(path.dirname(STORAGE_STATE), { recursive: true });

  await page.goto('/');

  const isKeycloakLogin = await page.locator('#username').isVisible({ timeout: 10_000 }).catch(() => false);

  if (isKeycloakLogin) {
    await page.locator('#username').fill('admin');
    await page.locator('#password').fill('admin');
    await page.locator('#kc-login').click();
    await page.waitForURL('**/chat**', { timeout: 15_000 });
  }

  await page.context().storageState({ path: STORAGE_STATE });
});
