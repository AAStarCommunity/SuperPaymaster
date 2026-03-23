// GET /.well-known/x-payment-info — x402 discovery endpoint

import { Hono } from "hono";
import { type Config } from "../lib/config.js";
import { getAccount } from "../lib/chain.js";
import type { PaymentInfo } from "../types.js";

export function wellKnownRoute(config: Config) {
  const app = new Hono();

  app.get("/.well-known/x-payment-info", (c) => {
    const account = getAccount();

    const resp: PaymentInfo = {
      facilitator: account.address,
      network: config.network,
      chainId: config.chainId,
      supportedAssets: [
        {
          address: config.usdcAddress,
          symbol: "USDC",
        },
      ],
      feeBPS: 200, // 2% default
      verifyUrl: `${config.baseUrl}/verify`,
      settleUrl: `${config.baseUrl}/settle`,
      quoteUrl: `${config.baseUrl}/quote`,
    };

    return c.json(resp);
  });

  return app;
}
