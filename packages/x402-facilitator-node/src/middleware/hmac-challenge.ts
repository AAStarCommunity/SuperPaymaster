// HMAC Challenge Middleware for x402 Facilitator Node
// Provides stateless bot-prevention via SHA-256 HMAC challenge-response.
//
// Flow:
// 1. Client makes initial request → 402 response includes X-Challenge header
// 2. Client computes HMAC(challenge, payment_data) and includes in X-PAYMENT-HMAC header
// 3. /settle verifies HMAC before executing settlement
//
// Enable via: ENABLE_HMAC_CHALLENGE=true and HMAC_SECRET=<your-secret>

import type { Context, Next } from "hono";

const CHALLENGE_TTL_MS = 300_000; // 5 minutes

function getHmacSecret(): string {
  const secret = process.env.HMAC_SECRET;
  if (!secret) throw new Error("HMAC_SECRET env var required when HMAC challenge is enabled");
  return secret;
}

export function isHmacEnabled(): boolean {
  return process.env.ENABLE_HMAC_CHALLENGE === "true";
}

async function hmacSha256(key: string, data: string): Promise<string> {
  const encoder = new TextEncoder();
  const cryptoKey = await crypto.subtle.importKey(
    "raw",
    encoder.encode(key),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign", "verify"],
  );
  const signature = await crypto.subtle.sign("HMAC", cryptoKey, encoder.encode(data));
  return Array.from(new Uint8Array(signature))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

/**
 * Generate a stateless challenge token.
 * Format: timestamp:hmac(timestamp, secret)
 * No server-side state needed — we can verify by recomputing.
 */
export async function generateChallenge(): Promise<string> {
  const timestamp = Date.now().toString();
  const mac = await hmacSha256(getHmacSecret(), `challenge:${timestamp}`);
  return `${timestamp}:${mac}`;
}

/**
 * Verify a challenge token is valid and not expired.
 */
export async function verifyChallenge(challenge: string): Promise<boolean> {
  const parts = challenge.split(":");
  if (parts.length !== 2) return false;

  const [timestamp, mac] = parts;
  const ts = Number(timestamp);
  if (isNaN(ts) || Date.now() - ts > CHALLENGE_TTL_MS) return false;

  const expected = await hmacSha256(getHmacSecret(), `challenge:${timestamp}`);
  return mac === expected;
}

/**
 * Verify that the client's HMAC response matches the expected value.
 * Client must compute: HMAC(challenge, JSON.stringify(paymentData))
 */
export async function verifyHmacResponse(
  challenge: string,
  paymentData: string,
  clientHmac: string,
): Promise<boolean> {
  const expected = await hmacSha256(challenge, paymentData);
  return expected === clientHmac;
}

/**
 * Hono middleware that injects X-Challenge header on 402 responses.
 */
export function hmacChallengeInjector() {
  return async (c: Context, next: Next) => {
    await next();
    if (c.res.status === 402 && isHmacEnabled()) {
      const challenge = await generateChallenge();
      c.res.headers.set("X-Challenge", challenge);
    }
  };
}

/**
 * Hono middleware that verifies HMAC on /settle requests.
 * Skips verification if HMAC is not enabled.
 */
export function hmacSettleGuard() {
  return async (c: Context, next: Next) => {
    if (!isHmacEnabled()) {
      await next();
      return;
    }

    const challenge = c.req.header("X-Challenge");
    const clientHmac = c.req.header("X-Payment-HMAC");

    if (!challenge || !clientHmac) {
      return c.json({ success: false, error: "Missing HMAC challenge/response headers" }, 400);
    }

    const challengeValid = await verifyChallenge(challenge);
    if (!challengeValid) {
      return c.json({ success: false, error: "Invalid or expired challenge" }, 400);
    }

    // Read body text for HMAC verification, then restore it
    const bodyText = await c.req.text();
    const hmacValid = await verifyHmacResponse(challenge, bodyText, clientHmac);
    if (!hmacValid) {
      return c.json({ success: false, error: "HMAC verification failed" }, 403);
    }

    await next();
  };
}
