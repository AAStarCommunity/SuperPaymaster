import { defineConfig } from '@playwright/test';

export default defineConfig({
  testDir: './tests',
  timeout: 30000,
  retries: 0,
  use: {
    baseURL: 'https://faucet-app-ashy.vercel.app',
    extraHTTPHeaders: {
      'Accept': 'application/json, text/html',
    },
  },
  reporter: [['list'], ['html']],
});
