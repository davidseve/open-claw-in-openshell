import { defineConfig, devices } from '@playwright/test';

const baseURL = process.env.OPENCLAW_BASE_URL || 'https://openclaw-gw--openclaw-ui.apps-crc.testing';

export default defineConfig({
  testDir: '.',
  outputDir: './test-results',
  timeout: 60_000,
  retries: 0,
  projects: [
    {
      name: 'auth-setup',
      testMatch: /auth\.setup\.ts/,
    },
    {
      name: 'ui-tests',
      testMatch: /openclaw-ui\.spec\.ts/,
      dependencies: ['auth-setup'],
      use: {
        storageState: './test-results/.auth/state.json',
      },
    },
    {
      name: 'security-tests',
      testMatch: /sandbox-security\.spec\.ts/,
      dependencies: ['auth-setup'],
      use: {
        storageState: './test-results/.auth/state.json',
      },
    },
  ],
  use: {
    baseURL,
    headless: true,
    ignoreHTTPSErrors: true,
    screenshot: 'only-on-failure',
    trace: 'retain-on-failure',
  },
  reporter: [
    ['list'],
    ['html', { open: 'never', outputFolder: './playwright-report' }],
  ],
});
