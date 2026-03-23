// Input validation utilities

import { isAddress, isHex } from "viem";

/** Validate an Ethereum address string */
export function validateAddress(value: unknown, field: string): `0x${string}` | string {
  if (typeof value !== "string" || !isAddress(value)) {
    return `Invalid ${field}: must be a valid Ethereum address`;
  }
  return value as `0x${string}`;
}

/** Validate a bytes32 hex string (nonce) */
export function validateBytes32(value: unknown, field: string): `0x${string}` | string {
  if (typeof value !== "string" || !isHex(value) || value.length !== 66) {
    return `Invalid ${field}: must be 0x + 64 hex chars`;
  }
  return value as `0x${string}`;
}

/** Validate a hex string (signature) */
export function validateHex(value: unknown, field: string): `0x${string}` | string {
  if (typeof value !== "string" || !isHex(value) || value.length < 4) {
    return `Invalid ${field}: must be a valid hex string`;
  }
  return value as `0x${string}`;
}

/** Validate a numeric string for BigInt conversion */
export function validateNumericString(value: unknown, field: string): string | null {
  if (typeof value !== "string" || !/^\d+$/.test(value)) {
    return `Invalid ${field}: must be a non-negative integer string`;
  }
  return null;
}

/** Validate all payment fields, return error string or null if valid */
export function validatePaymentFields(payment: Record<string, unknown>): string | null {
  const addrFields = ["from", "to", "asset"] as const;
  for (const f of addrFields) {
    const result = validateAddress(payment[f], f);
    if (typeof result === "string" && !result.startsWith("0x")) return result;
  }

  const nonceResult = validateBytes32(payment["nonce"], "nonce");
  if (typeof nonceResult === "string" && !nonceResult.startsWith("0x")) return nonceResult;

  const amountErr = validateNumericString(payment["amount"], "amount");
  if (amountErr) return amountErr;

  // validAfter/validBefore are optional for direct scheme
  if (payment["validAfter"] !== undefined) {
    const err = validateNumericString(payment["validAfter"], "validAfter");
    if (err) return err;
  }
  if (payment["validBefore"] !== undefined) {
    const err = validateNumericString(payment["validBefore"], "validBefore");
    if (err) return err;
  }

  return null;
}
