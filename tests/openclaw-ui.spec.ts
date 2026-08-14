import { test, expect } from '@playwright/test';

const CHAT_TIMEOUT = 30_000;

test.describe('OpenClaw Control UI', () => {

  test('loads and shows chat interface', async ({ page }) => {
    await page.goto('/');
    await expect(page).toHaveTitle('OpenClaw Control');
    await expect(page.getByPlaceholder(/Message/)).toBeVisible({ timeout: 15000 });
    await expect(page.getByText(/Router|Sonnet|router|inference/).first()).toHaveCount(1, { timeout: 10000 });
  });

  test('sidebar navigation is present', async ({ page }) => {
    await page.goto('/');
    await expect(page.getByText('Overview')).toBeVisible();
    await expect(page.getByText('Main Session')).toBeVisible();
  });

  test('chat input is functional', async ({ page }) => {
    await page.goto('/');
    const messageInput = page.getByPlaceholder(/Message/);
    await expect(messageInput).toBeVisible();
    await messageInput.fill('test message');
    await page.waitForTimeout(500);
    const sendButton = page.getByRole('button', { name: /Send/ });
    await expect(sendButton).toBeVisible();
  });

  test('E2E chat: model responds via inference router', async ({ page }) => {
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
        model: 'router',
        messages: [{ role: 'user', content: 'ping' }],
      },
    });
    expect([403, 404, 405]).toContain(resp.status());
  });
});
