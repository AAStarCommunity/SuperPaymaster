// POST /verify — Validate payment signature off-chain (~100ms)

import { Hono } from "hono";
import { type Config } from "../lib/config.js";
import { getPublicClient } from "../lib/chain.js";
import { X402_FACILITATOR_ABI } from "../lib/contracts.js";
import { verifyEIP3009Signature, verifyX402AuthSignature, computeX402NonceKey } from "../lib/verify-sig.js";
import { validatePaymentFields, validateHex } from "../lib/validate.js";
import type { VerifyRequest, VerifyResponse } from "../types.js";

export function verifyRoute(config: Config) {
  const app = new Hono();

  app.post("/verify", async (c) => {
    const body = await c.req.json<VerifyRequest>();

    if (!body.payment) {
      return c.json({ valid: false, reason: "Missing payment data" } satisfies VerifyResponse, 400);
    }

    // Validate all payment fields
    const validationError = validatePaymentFields(body.payment);
    if (validationError) {
      return c.json({ valid: false, reason: validationError } satisfies VerifyResponse, 400);
    }

    const { from, to, asset, amount, nonce, validAfter, validBefore, signature } = body.payment;

    // Only support EIP-3009 and direct for now
    if (body.scheme === "permit2") {
      return c.json({ valid: false, reason: "Permit2 scheme not yet supported in verify" } satisfies VerifyResponse, 400);
    }

    // Check nonce replay on-chain (X402Facilitator post v5.4 god-split).
    // The contract records spent nonces at the (asset, from, nonce) TRIPLE key
    // (x402SettlementNonces[keccak256(abi.encode(asset, from, nonce))]), and only checks
    // the raw nonce slot for legacy pre-V5.4 entries. We mirror BOTH lookups so a replay
    // is detected exactly when X402Facilitator._validateX402AndComputeFee would revert
    // NonceAlreadyUsed. This holds for both schemes: for EIP-3009 `nonce` is the token-level
    // authorization nonce (= keccak256(to, maxFee, salt)) the payer signed and the contract
    // passes to receiveWithAuthorization; for direct it is the X402PaymentAuthorization nonce.
    const client = getPublicClient();
    const nonceKey = computeX402NonceKey(asset, from, nonce);
    const [keyUsed, legacyUsed] = await Promise.all([
      client.readContract({
        address: config.x402FacilitatorAddress,
        abi: X402_FACILITATOR_ABI,
        functionName: "x402SettlementNonces",
        args: [nonceKey],
      }),
      client.readContract({
        address: config.x402FacilitatorAddress,
        abi: X402_FACILITATOR_ABI,
        functionName: "x402SettlementNonces",
        args: [nonce],
      }),
    ]);

    if (keyUsed || legacyUsed) {
      return c.json({ valid: false, reason: "Nonce already used" } satisfies VerifyResponse, 400);
    }

    if (body.scheme === "direct") {
      // Direct scheme (xPNTs): payer must sign an X402PaymentAuthorization bound to the
      // X402Facilitator EIP-712 domain. C-02: verify it off-chain before settle.
      const maxFee = (body.payment as { maxFee?: string | number | bigint }).maxFee;
      const directResult = await verifyX402AuthSignature({
        from,
        to,
        asset,
        amount: BigInt(amount),
        maxFee: BigInt(maxFee ?? amount),
        validBefore: BigInt(validBefore),
        nonce,
        signature,
        chainId: config.chainId,
        facilitatorAddress: config.x402FacilitatorAddress,
      });

      if (!directResult.valid) {
        return c.json({ valid: false, reason: directResult.reason } satisfies VerifyResponse, 400);
      }

      return c.json({
        valid: true,
        payer: from,
        amount,
        asset,
      } satisfies VerifyResponse);
    }

    // EIP-3009: verify signature off-chain. v5.4 god-split: the receiveWithAuthorization
    // recipient (value.to) is the X402Facilitator contract, which pulls USDC in before
    // forwarding to the final recipient.
    const result = await verifyEIP3009Signature({
      from,
      to: config.x402FacilitatorAddress, // USDC goes to X402Facilitator first
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
