// POST /verify — Validate payment signature off-chain (~100ms)

import { Hono } from "hono";
import { type Config } from "../lib/config.js";
import { getPublicClient } from "../lib/chain.js";
import { SUPER_PAYMASTER_ABI } from "../lib/contracts.js";
import { verifyEIP3009Signature } from "../lib/verify-sig.js";
import type { VerifyRequest, VerifyResponse } from "../types.js";

export function verifyRoute(config: Config) {
  const app = new Hono();

  app.post("/verify", async (c) => {
    const body = await c.req.json<VerifyRequest>();

    if (!body.payment) {
      return c.json({ valid: false, reason: "Missing payment data" } satisfies VerifyResponse, 400);
    }

    const { from, to, asset, amount, nonce, validAfter, validBefore, signature } = body.payment;

    // Only support EIP-3009 and direct for now
    if (body.scheme === "permit2") {
      return c.json({ valid: false, reason: "Permit2 scheme not yet supported in verify" } satisfies VerifyResponse, 400);
    }

    // Check nonce replay on-chain
    const client = getPublicClient();
    const nonceUsed = await client.readContract({
      address: config.superPaymasterAddress,
      abi: SUPER_PAYMASTER_ABI,
      functionName: "x402SettlementNonces",
      args: [nonce],
    });

    if (nonceUsed) {
      return c.json({ valid: false, reason: "Nonce already used" } satisfies VerifyResponse, 400);
    }

    if (body.scheme === "direct") {
      // Direct scheme: no signature to verify, just validate params
      return c.json({
        valid: true,
        payer: from,
        amount,
        asset,
      } satisfies VerifyResponse);
    }

    // EIP-3009: verify signature off-chain
    const result = await verifyEIP3009Signature({
      from,
      to: config.superPaymasterAddress, // USDC goes to SuperPaymaster first
      amount: BigInt(amount),
      validAfter: BigInt(validAfter),
      validBefore: BigInt(validBefore),
      nonce,
      signature,
      chainId: config.chainId,
      usdcAddress: config.usdcAddress,
    });

    if (!result.valid) {
      return c.json({ valid: false, reason: result.reason } satisfies VerifyResponse, 400);
    }

    return c.json({
      valid: true,
      payer: from,
      amount,
      asset,
    } satisfies VerifyResponse);
  });

  return app;
}
