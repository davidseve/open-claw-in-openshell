import { test as setup, expect } from '@playwright/test';
import * as fs from 'fs';
import * as path from 'path';

const STORAGE_STATE = path.join(__dirname, 'test-results', '.auth', 'state.json');

// Since ADR-0016, the Control UI is protected by oauth-proxy (OpenShift fork,
// `-provider=openshift`), which sends unauthenticated browsers to OCP's own
// OAuth server login form -- no Keycloak in this path. On this CRC cluster
// the OAuth server's identity provider is HTPasswd; the form fields below
// (#inputUsername/#inputPassword/#co-login-button) are OCP's own login page
// markup, not oauth-proxy's.
const OCP_USERNAME = process.env.OCP_TEST_USERNAME || 'developer';
const OCP_PASSWORD = process.env.OCP_TEST_PASSWORD || 'developer';

setup('authenticate via OpenShift-native OAuth', async ({ page }) => {
  fs.mkdirSync(path.dirname(STORAGE_STATE), { recursive: true });

  await page.goto('/');

  const isOcpLogin = await page.locator('#inputUsername').isVisible({ timeout: 10_000 }).catch(() => false);

  if (isOcpLogin) {
    await page.locator('#inputUsername').fill(OCP_USERNAME);
    await page.locator('#inputPassword').fill(OCP_PASSWORD);
    await page.locator('#co-login-button').click();

    // Some OCP OAuth clients require an explicit consent/approve step
    // (approval_prompt=force). Handle it if present; a previously-granted
    // client (persisted OAuthClientAuthorization) skips straight to the app.
    const approveButton = page.getByRole('button', { name: /allow selected permissions/i });
    if (await approveButton.isVisible({ timeout: 3_000 }).catch(() => false)) {
      await approveButton.click();
    }

    await page.waitForURL(/\/(chat|conversation|home|$)/, { timeout: 15_000 });
  }

  await page.context().storageState({ path: STORAGE_STATE });
});
