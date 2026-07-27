import { test, expect, Page } from '@playwright/test';

const WORKSPACE = process.env.MLFLOW_WORKSPACE || 'openshell';
const EXPERIMENT_ID = process.env.MLFLOW_EXPERIMENT_ID || '1';

async function selectWorkspace(page: Page) {
  // Paths must be relative to baseURL (…/mlflow/). A leading `/` would drop the /mlflow prefix.
  await page.goto('./');
  const workspace = page.getByText(WORKSPACE, { exact: true });
  await expect(workspace).toBeVisible({ timeout: 15_000 });
  await workspace.click();
  await page.waitForTimeout(1500);
}

test.describe('RHOAI MLflow UI', () => {

  test.beforeEach(async ({ page }) => {
    await selectWorkspace(page);
  });

  test('loads GenAI studio with openclaw-tracing experiment', async ({ page }) => {
    await page.goto(`./#/experiments/${EXPERIMENT_ID}`);
    await expect(page.getByRole('link', { name: 'openclaw-tracing' }).first()).toBeVisible({ timeout: 15_000 });
    await expect(page.getByText('Traces', { exact: true })).toBeVisible();
  });

  test('shows seeded prompts in Prompts tab', async ({ page }) => {
    await page.goto('./#/prompts');
    await expect(page.getByText('Prompts', { exact: true }).first()).toBeVisible({ timeout: 15_000 });

    for (const name of ['AGENTS', 'SOUL', 'TOOLS', 'IDENTITY', 'USER', 'HEARTBEAT', 'BOOTSTRAP']) {
      await expect(page.getByText(`openclaw-system.${name}`)).toBeVisible({ timeout: 10_000 });
    }
  });

  test('shows agent traces in Traces tab', async ({ page }) => {
    await page.goto(`./#/experiments/${EXPERIMENT_ID}/traces`);
    await expect(page.getByText('Trace ID')).toBeVisible({ timeout: 15_000 });

    const traceRows = page.locator('text=/tr-[0-9a-f]{32}/');
    await expect(traceRows.first()).toBeVisible({ timeout: 15_000 });

    const count = await traceRows.count();
    expect(count).toBeGreaterThan(0);
  });

  test('trace list includes E2E chat content from Control UI', async ({ page }) => {
    await page.goto(`./#/experiments/${EXPERIMENT_ID}/traces`);
    await expect(page.getByText('Trace ID')).toBeVisible({ timeout: 15_000 });

    // Layer 9's Playwright chat sends "Respond with exactly one word: PONG"
    await expect(page.getByText(/PONG|Respond with exactly one word/i).first()).toBeVisible({
      timeout: 15_000,
    });
  });

  test('traces table shows linked prompts in the Prompt column', async ({ page }) => {
    // scripts/prompt-registry/prompt-trace-linker.js tags every trace with
    // mlflow.linkedPrompts. MLflow renders this as a dedicated "Prompt"
    // column in the Traces table (confirmed live via the Columns selector
    // in this MLflow version, 3.10.1) — hidden by default, so it must be
    // enabled first. Cell text looks like:
    //   "openclaw-system.AGENTS/1, openclaw-system.SOUL/1, ..."
    await page.goto(`./#/experiments/${EXPERIMENT_ID}/traces`);
    await expect(page.getByText('Trace ID')).toBeVisible({ timeout: 15_000 });

    await page.getByRole('button', { name: 'Columns' }).click();
    await page.getByRole('searchbox', { name: 'Search' }).fill('Prompt');
    await page.getByRole('option').filter({ hasText: 'Prompt' }).first().click();
    await page.keyboard.press('Escape');

    await expect(page.getByRole('columnheader', { name: 'Prompt' })).toBeVisible({ timeout: 10_000 });

    const promptCell = page.getByText(/openclaw-system\.AGENTS\/\d+/).first();
    await expect(promptCell).toBeVisible({ timeout: 15_000 });
    for (const name of ['SOUL', 'TOOLS', 'IDENTITY', 'USER', 'HEARTBEAT']) {
      await expect(promptCell).toContainText(new RegExp(`openclaw-system\\.${name}/\\d+`));
    }
  });
});
