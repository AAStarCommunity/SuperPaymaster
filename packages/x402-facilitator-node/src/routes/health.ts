// GET /health — Operator status check

import { Hono } from "hono";
import { getPublicClient, getAccount } from "../lib/chain.js";
import { X402_FACILITATOR_ABI } from "../lib/contracts.js";
import { type Config } from "../lib/config.js";
import type { HealthResponse } from "../types.js";

export function healthRoute(config: Config) {
  const app = new Hono();

  app.get("/health", async (c) => {
    try {
      const client = getPublicClient();
      const account = getAccount();

      const [blockNumber, contractVersion] = await Promise.all([
        client.getBlockNumber(),
        client.readContract({
          address: config.x402FacilitatorAddress,
          abi: X402_FACILITATOR_ABI,
          functionName: "version",
        }) as Promise<string>,
      ]);

      const resp: HealthResponse = {
        status: "ok",
        version: "0.1.0",
        chainId: config.chainId,
        network: config.network,
        operator: account.address,
        contractVersion,
        blockNumber: Number(blockNumber),
      };
      return c.json(resp);
    } catch (err) {
      console.error("Health check failed:", err);
      return c.json({
        status: "degraded",
        version: "0.1.0",
        chainId: config.chainId,
        network: config.network,
        operator: "0x0000000000000000000000000000000000000000" as `0x${string}`,
      } satisfies HealthResponse, 503);
    }
  });

  return app;
}
