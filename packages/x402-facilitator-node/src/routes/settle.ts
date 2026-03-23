// POST /settle — Execute on-chain settlement (~2s on Base)

import { Hono } from "hono";
import { type Config } from "../lib/config.js";
import { getPublicClient, getWalletClient, getAccount } from "../lib/chain.js";
import { SUPER_PAYMASTER_ABI } from "../lib/contracts.js";
import type { SettleRequest, SettleResponse } from "../types.js";

export function settleRoute(config: Config) {
  const app = new Hono();

  app.post("/settle", async (c) => {
    const body = await c.req.json<SettleRequest>();

    if (!body.payment) {
      return c.json({ success: false, error: "Missing payment data" } satisfies SettleResponse, 400);
    }

    const { from, to, asset, amount, nonce, validAfter, validBefore, signature } = body.payment;
    const publicClient = getPublicClient();
    const walletClient = getWalletClient();
    const account = getAccount();

    try {
      if (body.scheme === "direct") {
        // settleX402PaymentDirect — for xPNTs and pre-approved tokens
        const { request } = await publicClient.simulateContract({
          account: account,
          address: config.superPaymasterAddress,
          abi: SUPER_PAYMASTER_ABI,
          functionName: "settleX402PaymentDirect",
          args: [
            from as `0x${string}`,
            to as `0x${string}`,
            asset as `0x${string}`,
            BigInt(amount),
            nonce as `0x${string}`,
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
        address: config.superPaymasterAddress,
        abi: SUPER_PAYMASTER_ABI,
        functionName: "settleX402Payment",
        args: [
          from as `0x${string}`,
          to as `0x${string}`,
          asset as `0x${string}`,
          BigInt(amount),
          BigInt(validAfter),
          BigInt(validBefore),
          nonce as `0x${string}`,
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
      const message = err instanceof Error ? err.message : "Settlement failed";
      return c.json({ success: false, error: message } satisfies SettleResponse, 500);
    }
  });

  return app;
}
