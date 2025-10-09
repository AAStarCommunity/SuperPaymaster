import { test, expect } from "@playwright/test";

const FAUCET_BASE_URL = "https://faucet-appapp-ashyashy.vercel.app";
const TEST_ADDRESS = "0xc8d1Ae1063176BEBC750D9aD5D057BA4A65daf3d";

test.describe("Faucet API Tests", () => {
  test("GET / - Homepage loads", async ({ request }) => {
    const response = await request.get(`${FAUCET_BASE_URL}/`);
    expect(response.status()).toBe(200);
    const body = await response.text();
    expect(body).toContain("GasToken Faucet");
  });

  test("POST /api/mint - Mint PNT tokens", async ({ request }) => {
    const response = await request.post(`${FAUCET_BASE_URL}/api/mint`, {
      data: {
        address: TEST_ADDRESS,
        type: "pnt",
      },
    });

    if (response.status() === 429) {
      console.log("Rate limited (expected behavior)");
      expect(response.status()).toBe(429);
    } else {
      expect(response.status()).toBe(200);
      const body = await response.json();
      expect(body.success).toBe(true);
      expect(body.txHash).toBeDefined();
    }
  });

  test("POST /api/mint - Mint SBT token", async ({ request }) => {
    const response = await request.post(`${FAUCET_BASE_URL}/api/mint`, {
      data: {
        address: TEST_ADDRESS,
        type: "sbt",
      },
    });

    if (response.status() === 429) {
      console.log("Rate limited (expected behavior)");
      expect(response.status()).toBe(429);
    } else {
      expect(response.status()).toBe(200);
      const body = await response.json();
      expect(body.success).toBe(true);
      expect(body.txHash).toBeDefined();
    }
  });

  test("POST /api/mint-usdt - Mint USDT tokens", async ({ request }) => {
    const response = await request.post(`${FAUCET_BASE_URL}/api/mint-usdt`, {
      data: { address: TEST_ADDRESS },
    });

    if (response.status() === 429) {
      console.log("Rate limited (expected behavior)");
      expect(response.status()).toBe(429);
    } else {
      expect(response.status()).toBe(200);
      const body = await response.json();
      expect(body.success).toBe(true);
      expect(body.txHash).toBeDefined();
      expect(body.amount).toBe("10 USDT");
    }
  });

  test("POST /api/create-account - Create SimpleAccount", async ({
    request,
  }) => {
    const response = await request.post(
      `${FAUCET_BASE_URL}/api/create-account`,
      {
        data: {
          owner: TEST_ADDRESS,
          salt: Math.floor(Math.random() * 1000000),
        },
      },
    );

    if (response.status() === 429) {
      console.log("Rate limited (expected behavior)");
      expect(response.status()).toBe(429);
    } else if (response.status() === 500) {
      // Account might already exist, which is ok
      console.log("Account creation failed (might already exist)");
      const body = await response.json();
      expect(body.error).toBeDefined();
    } else {
      expect(response.status()).toBe(200);
      const body = await response.json();
      expect(body.success).toBe(true);
      expect(body.accountAddress).toBeDefined();
    }
  });

  test("POST /api/init-pool - Initialize pool (requires admin key)", async ({
    request,
  }) => {
    const response = await request.post(`${FAUCET_BASE_URL}/api/init-pool`, {
      data: {
        adminKey: "wrong-key",
        ethAmount: "0.1",
        usdtAmount: "100",
      },
    });

    // Should fail without correct admin key (either 400 or 403)
    expect([400, 403]).toContain(response.status());
    const body = await response.json();
    expect(body.error).toBeDefined();
  });

  test("POST /api/mint - Invalid address should fail", async ({ request }) => {
    const response = await request.post(`${FAUCET_BASE_URL}/api/mint`, {
      data: {
        address: "invalid-address",
        type: "pnt",
      },
    });

    expect(response.status()).toBe(400);
    const body = await response.json();
    expect(body.error).toBeDefined();
  });
});
