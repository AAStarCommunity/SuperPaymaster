// POST /settle — Execute on-chain settlement (~2s on Base)

import { Hono } from "hono";
import { type Config } from "../lib/config.js";
import { getPublicClient, getWalletClient, getAccount } from "../lib/chain.js";
import { X402_FACILITATOR_ABI } from "../lib/contracts.js";
import { validatePaymentFields, validateHex } from "../lib/validate.js";
import type { SettleRequest, SettleResponse } from "../types.js";

export function settleRoute(config: Config) {
  const app = new Hono();

  app.post("/settle", async (c) => {
    const body = await c.req.json<SettleRequest>();

    if (!body.payment) {
      return c.json({ success: false, error: "Missing payment data" } satisfies SettleResponse, 400);
    }

    // Validate all payment fields
    const validationError = validatePaymentFields(body.payment);
    if (validationError) {
      return c.json({ success: false, error: validationError } satisfies SettleResponse, 400);
    }

    // Validate signature for non-direct schemes
    if (body.scheme !== "direct") {
      const sigResult = validateHex(body.payment.signature, "signature");
      if (typeof sigResult === "string" && !sigResult.startsWith("0x")) {
        return c.json({ success: false, error: sigResult } satisfies SettleResponse, 400);
      }
    }

    const { from, to, asset, amount, nonce, validAfter, validBefore, signature } = body.payment;
    // PENDING aastar-sdk#39: C-02/C-03 settlement requires a payer EIP-712 signature
    // (direct path) and a recipient-bound salt (EIP-3009 path). These are read from the
    // payment payload once the SDK produces them; the fallbacks below keep the deprecated
    // in-repo node type-correct against the new ABI but are NOT a substitute for the SDK.
    const maxFee = (body.payment as { maxFee?: string | number | bigint }).maxFee;
    const salt = (body.payment as { salt?: string }).salt ?? nonce;
    const publicClient = getPublicClient();
    const walletClient = getWalletClient();
    const account = getAccount();

    try {
      if (body.scheme === "direct") {
        // settleX402PaymentDirect — for xPNTs and pre-approved tokens
        const { request } = await publicClient.simulateContract({
          account: account,
          address: config.x402FacilitatorAddress,
          abi: X402_FACILITATOR_ABI,
          functionName: "settleX402PaymentDirect",
          args: [
            from as `0x${string}`,
            to as `0x${string}`,
            asset as `0x${string}`,
            BigInt(amount),
            BigInt(maxFee ?? amount), // C-02: fee cap; SDK supplies the signed maxFee
            BigInt(validBefore),
            nonce as `0x${string}`,
            signature as `0x${string}`, // C-02: payer X402PaymentAuthorization signature
          ],
        });

        const txHash = await walletClient.writeContract(request);
        const receipt = await publicClient.waitForTransactionReceipt({ hash: txHash });

        return c.json({
          success: receipt.status === "success",
          txHash,
          settlementId: nonce, // Use nonce as settlement ID reference
        } satisfies SettleResponse);
      }

      // Default: EIP-3009 settlement
      const { request } = await publicClient.simulateContract({
        account: account,
        address: config.x402FacilitatorAddress,
        abi: X402_FACILITATOR_ABI,
        functionName: "settleX402Payment",
        args: [
          from as `0x${string}`,
          to as `0x${string}`,
          asset as `0x${string}`,
          BigInt(amount),
          BigInt(maxFee ?? amount), // M-1: fee cap bound into nonce = keccak256(to, maxFee, salt)
          BigInt(validAfter),
          BigInt(validBefore),
          salt as `0x${string}`, // C-03/M-1: on-chain nonce = keccak256(to, maxFee, salt)
          signature as `0x${string}`,
        ],
      });

      const txHash = await walletClient.writeContract(request);
      const receipt = await publicClient.waitForTransactionReceipt({ hash: txHash });

      return c.json({
        success: receipt.status === "success",
        txHash,
        settlementId: nonce,
      } satisfies SettleResponse);
    } catch (err) {
      console.error("Settlement error:", err);
      // Return generic message to avoid leaking internal details
      const isRevert = err instanceof Error && err.message.includes("revert");
      return c.json(
        { success: false, error: isRevert ? "Transaction reverted" : "Settlement failed" } satisfies SettleResponse,
        isRevert ? 400 : 500,
      );
    }
  });

  return app;
}
