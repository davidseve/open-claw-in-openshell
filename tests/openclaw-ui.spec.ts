import { test, expect } from '@playwright/test';

const CHAT_TIMEOUT = 30_000;

test.describe('OpenClaw Control UI', () => {

  test('loads and shows Health OK', async ({ page }) => {
    await page.goto('/');
    await expect(page).toHaveTitle('OpenClaw Control');
    await expect(page.getByText('Health').first()).toBeVisible();
    await expect(page.getByText('OK').first()).toBeVisible();
    await expect(page.getByText(/Version\s+\d/).first()).toBeVisible();
  });

  test('sidebar navigation is present', async ({ page }) => {
    await page.goto('/');
    for (const section of ['Chat', 'Overview', 'Channels', 'Instances', 'Sessions', 'Usage']) {
      await expect(page.getByRole('link', { name: section }).first()).toBeVisible();
    }
  });

  test('chat input is functional', async ({ page }) => {
    await page.goto('/');
    const messageInput = page.getByPlaceholder(/Message/);
    await expect(messageInput).toBeVisible();
    await expect(page.getByRole('button', { name: /Send/ })).toBeVisible();
  });

  test('E2E chat: Claude responds via MaaS', async ({ page }) => {
    await page.goto('/');

    const messageInput = page.getByPlaceholder(/Message/);
    await messageInput.waitFor({ state: 'visible' });

    await page.waitForTimeout(2000);

    await messageInput.fill('Respond with exactly one word: PONG');
    await page.getByRole('button', { name: /Send/ }).click();

    const response = page.locator('text=PONG').last();
    await expect(response).toBeVisible({ timeout: CHAT_TIMEOUT });
  });

  test('health API returns ok', async ({ request }) => {
    const resp = await request.get('/health');
    expect(resp.ok()).toBeTruthy();
    const body = await resp.json();
    expect(body.ok).toBe(true);
  });

  test('chat completions HTTP API is disabled', async ({ request }) => {
    const resp = await request.post('/v1/chat/completions', {
      data: {
        model: 'claude-sonnet-4-6',
        messages: [{ role: 'user', content: 'ping' }],
      },
    });
    expect([403, 404, 405]).toContain(resp.status());
  });
});
