// EIP-3009 signature verification utilities

import { verifyTypedData, type Address } from "viem";

// EIP-712 domain for USDC (Circle's implementation)
export function getUsdcDomain(chainId: number, usdcAddress: Address) {
  return {
    name: "USDC",
    version: "2",
    chainId: BigInt(chainId),
    verifyingContract: usdcAddress,
  } as const;
}

const TRANSFER_WITH_AUTH_TYPES = {
  TransferWithAuthorization: [
    { name: "from", type: "address" },
    { name: "to", type: "address" },
    { name: "value", type: "uint256" },
    { name: "validAfter", type: "uint256" },
    { name: "validBefore", type: "uint256" },
    { name: "nonce", type: "bytes32" },
  ],
} as const;

/**
 * Verify an EIP-3009 TransferWithAuthorization signature off-chain.
 * Returns the recovered signer address if valid, null otherwise.
 */
export async function verifyEIP3009Signature(params: {
  from: Address;
  to: Address;
  amount: bigint;
  validAfter: bigint;
  validBefore: bigint;
  nonce: `0x${string}`;
  signature: `0x${string}`;
  chainId: number;
  usdcAddress: Address;
}): Promise<{ valid: boolean; signer?: Address; reason?: string }> {
  const now = BigInt(Math.floor(Date.now() / 1000));

  // Time window validation
  if (params.validAfter > 0n && now < params.validAfter) {
    return { valid: false, reason: "Payment not yet valid (validAfter)" };
  }
  if (now >= params.validBefore) {
    return { valid: false, reason: "Payment expired (validBefore)" };
  }

  // Amount sanity check
  if (params.amount === 0n) {
    return { valid: false, reason: "Zero amount" };
  }

  try {
    const domain = getUsdcDomain(params.chainId, params.usdcAddress);
    const valid = await verifyTypedData({
      address: params.from,
      domain,
      types: TRANSFER_WITH_AUTH_TYPES,
      primaryType: "TransferWithAuthorization",
      message: {
        from: params.from,
        to: params.to,
        value: params.amount,
        validAfter: params.validAfter,
        validBefore: params.validBefore,
        nonce: params.nonce,
      },
      signature: params.signature,
    });

    if (!valid) {
      return { valid: false, reason: "Invalid signature" };
    }

    return { valid: true, signer: params.from };
  } catch {
    return { valid: false, reason: "Signature verification failed" };
  }
}
