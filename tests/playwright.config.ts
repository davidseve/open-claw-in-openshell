import { defineConfig, devices } from '@playwright/test';
import { loadLocalSecretsEnv } from './load-secrets-env';

loadLocalSecretsEnv();

const baseURL = process.env.OPENCLAW_BASE_URL || 'https://openclaw-gw--openclaw-ui.apps-crc.testing';
const mlflowBaseURL = (process.env.MLFLOW_BASE_URL || 'https://mlflow-redhat-ods-applications.apps-crc.testing/mlflow').replace(/\/?$/, '/');

const mlflowAuthHeaders: Record<string, string> = {};
if (process.env.MLFLOW_AUTH_TOKEN) {
  mlflowAuthHeaders['Authorization'] = `Bearer ${process.env.MLFLOW_AUTH_TOKEN}`;
}
if (process.env.MLFLOW_WORKSPACE) {
  mlflowAuthHeaders['X-MLFLOW-WORKSPACE'] = process.env.MLFLOW_WORKSPACE;
}

export default defineConfig({
  testDir: '.',
  outputDir: './test-results',
  timeout: 60_000,
  retries: 1,
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
    {
      name: 'mlflow-ui-tests',
      testMatch: /mlflow-ui\.spec\.ts/,
      dependencies: ['ui-tests'],
      use: {
        baseURL: mlflowBaseURL,
        extraHTTPHeaders: mlflowAuthHeaders,
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
