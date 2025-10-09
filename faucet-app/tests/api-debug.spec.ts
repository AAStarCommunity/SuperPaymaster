import { test, expect } from '@playwright/test';

test('Debug API request', async ({ request }) => {
  const url = 'https://faucet-app-ashy.vercel.app/api/mint';

  console.log('Testing URL:', url);

  const response = await request.post(url, {
    data: {
      address: '0xc8d1Ae1063176BEBC750D9aD5D057BA4A65daf3d',
      type: 'pnt'
    }
  });

  console.log('Status:', response.status());
  console.log('Headers:', await response.headersArray());

  const body = await response.text();
  console.log('Body:', body);

  expect(response.status()).not.toBe(404);
});
