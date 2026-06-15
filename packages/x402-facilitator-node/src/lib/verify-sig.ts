// EIP-3009 + X402Facilitator signature verification utilities

import { verifyTypedData, keccak256, encodeAbiParameters, type Address } from "viem";

/**
 * Mirror X402Facilitator.x402NonceKey(asset, from, nonce):
 *   keccak256(abi.encode(address asset, address from, bytes32 nonce))
 *
 * The contract records spent settlement nonces at THIS key in `x402SettlementNonces`
 * (X402Facilitator._validateX402AndComputeFee writes `x402SettlementNonces[key] = true`),
 * NOT at the raw `nonce` slot. The raw-nonce slot is only checked for legacy pre-V5.4
 * entries. A replay check that queries the raw nonce therefore always misses real replays.
 * This must stay byte-for-byte identical to the Solidity `abi.encode(address,address,bytes32)`.
 */
export function computeX402NonceKey(
  asset: Address,
  from: Address,
  nonce: `0x${string}`,
): `0x${string}` {
  return keccak256(
    encodeAbiParameters(
      [{ type: "address" }, { type: "address" }, { type: "bytes32" }],
      [asset, from, nonce],
    ),
  );
}

/**
 * Mirror X402Facilitator.settleX402Payment's on-chain EIP-3009 nonce derivation:
 *   nonce = keccak256(abi.encode(address to, uint256 maxFee, bytes32 salt))   (X402Facilitator.sol)
 *
 * C-03/M-1: the EIP-3009 path binds the final recipient `to` AND the payer-approved fee cap
 * `maxFee` into the token-level nonce. The contract takes the preimage `salt` and computes this
 * nonce itself, then submits it to receiveWithAuthorization, so the payer's EIP-3009 signature
 * and the on-chain replay key are BOTH keyed on this derived value — NOT on the raw `salt`.
 * verify.ts MUST therefore verify the signature and the replay slot against this same derived
 * nonce, exactly as settle.ts lets the contract derive it. `to` here is the FINAL recipient
 * (the function `to` param), distinct from the EIP-3009 token recipient (= the facilitator).
 * Must stay byte-for-byte identical to the Solidity `abi.encode(address,uint256,bytes32)`.
 */
export function computeEIP3009Nonce(
  to: Address,
  maxFee: bigint,
  salt: `0x${string}`,
): `0x${string}` {
  return keccak256(
    encodeAbiParameters(
      [{ type: "address" }, { type: "uint256" }, { type: "bytes32" }],
      [to, maxFee, salt],
    ),
  );
}

// EIP-712 domain for USDC (Circle's implementation)
export function getUsdcDomain(chainId: number, usdcAddress: Address) {
  return {
    name: "USDC",
    version: "2",
    chainId: BigInt(chainId),
    verifyingContract: usdcAddress,
  } as const;
}

// EIP-712 domain for the X402Facilitator contract.
// v5.4 god-split: the X402PaymentAuthorization signature (direct path) is recovered by
// X402Facilitator._x402DomainSeparator, which uses name="X402Facilitator", version="1",
// and verifyingContract = the facilitator contract address. A wrong name or verifyingContract
// makes every signature recovery yield the wrong signer, so settlement reverts.
export function getX402FacilitatorDomain(chainId: number, facilitatorAddress: Address) {
  return {
    name: "X402Facilitator",
    version: "1",
    chainId: BigInt(chainId),
    verifyingContract: facilitatorAddress,
  } as const;
}

// Matches X402Facilitator.X402_AUTH_TYPEHASH:
// "X402PaymentAuthorization(address from,address to,address asset,uint256 amount,uint256 maxFee,uint256 validBefore,bytes32 nonce)"
export const X402_AUTH_TYPES = {
  X402PaymentAuthorization: [
    { name: "from", type: "address" },
    { name: "to", type: "address" },
    { name: "asset", type: "address" },
    { name: "amount", type: "uint256" },
    { name: "maxFee", type: "uint256" },
    { name: "validBefore", type: "uint256" },
    { name: "nonce", type: "bytes32" },
  ],
} as const;

/**
 * Verify a payer's X402PaymentAuthorization signature off-chain against the
 * X402Facilitator EIP-712 domain (direct settlement path). Returns valid + reason.
 * Note: only validates EOA signatures off-chain; on-chain the contract additionally
 * accepts ERC-1271 (AirAccount / smart-account) signatures via SignatureCheckerLib.
 */
export async function verifyX402AuthSignature(params: {
  from: Address;
  to: Address;
  asset: Address;
  amount: bigint;
  maxFee: bigint;
  validBefore: bigint;
  nonce: `0x${string}`;
  signature: `0x${string}`;
  chainId: number;
  facilitatorAddress: Address;
}): Promise<{ valid: boolean; reason?: string }> {
  const now = BigInt(Math.floor(Date.now() / 1000));
  if (now > params.validBefore) {
    return { valid: false, reason: "Authorization expired (validBefore)" };
  }
  if (params.amount === 0n) {
    return { valid: false, reason: "Zero amount" };
  }

  try {
    const domain = getX402FacilitatorDomain(params.chainId, params.facilitatorAddress);
    const valid = await verifyTypedData({
      address: params.from,
      domain,
      types: X402_AUTH_TYPES,
      primaryType: "X402PaymentAuthorization",
      message: {
        from: params.from,
        to: params.to,
        asset: params.asset,
        amount: params.amount,
        maxFee: params.maxFee,
        validBefore: params.validBefore,
        nonce: params.nonce,
      },
      signature: params.signature,
    });

    if (!valid) {
      // May be an ERC-1271 smart-account signature, which only the contract can verify.
      return { valid: false, reason: "Invalid X402 authorization signature (EOA check)" };
    }
    return { valid: true };
  } catch {
    return { valid: false, reason: "X402 authorization verification failed" };
  }
}

// X402Facilitator.settleX402Payment calls IERC3009(asset).receiveWithAuthorization(...),
// NOT transferWithAuthorization (see X402Facilitator.sol — the receive variant forces the
// token to enforce msg.sender == to, closing a front-run nonce-burn grief vector). The two
// EIP-3009 variants sign IDENTICAL fields but DIFFERENT typehash strings, so the payer's
// signature recovers `from` only when verified against the ReceiveWithAuthorization typehash.
// Verifying against TransferWithAuthorization would recover a different address and reject
// every valid receive signature.
export const RECEIVE_WITH_AUTH_TYPES = {
  ReceiveWithAuthorization: [
    { name: "from", type: "address" },
    { name: "to", type: "address" },
    { name: "value", type: "uint256" },
    { name: "validAfter", type: "uint256" },
    { name: "validBefore", type: "uint256" },
    { name: "nonce", type: "bytes32" },
  ],
} as const;

/**
 * Verify an EIP-3009 ReceiveWithAuthorization signature off-chain.
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
      types: RECEIVE_WITH_AUTH_TYPES,
      primaryType: "ReceiveWithAuthorization",
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
