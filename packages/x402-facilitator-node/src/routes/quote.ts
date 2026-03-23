// GET /quote — Operator fee rate and supported assets

import { Hono } from "hono";
import { type Config } from "../lib/config.js";
import { getPublicClient } from "../lib/chain.js";
import { SUPER_PAYMASTER_ABI } from "../lib/contracts.js";
import type { QuoteResponse } from "../types.js";

export function quoteRoute(config: Config) {
  const app = new Hono();

  app.get("/quote", async (c) => {
    const client = getPublicClient();

    const feeBPS = await client.readContract({
      address: config.superPaymasterAddress,
      abi: SUPER_PAYMASTER_ABI,
      functionName: "facilitatorFeeBPS",
    }) as bigint;

    const resp: QuoteResponse = {
      feeBPS: Number(feeBPS),
      feePercent: `${Number(feeBPS) / 100}%`,
      supportedAssets: [
        {
          address: config.usdcAddress,
          symbol: "USDC",
          network: config.network,
        },
      ],
      supportedSchemes: ["eip-3009", "direct"],
    };

    return c.json(resp);
  });

  return app;
}
