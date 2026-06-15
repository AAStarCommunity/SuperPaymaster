// Pure builders for the on-chain settlement call arguments.
//
// Codex stop-review flagged verify/settle/contract ABI mismatches. The exact ON-CHAIN arg
// ORDER is part of the contract signature and cannot drift: a single transposed argument
// reverts (or, worse, mis-settles). These builders are the SOLE source of the `args` arrays
// passed to viem's simulateContract in settle.ts, so a unit test can lock the order against
// the X402Facilitator ABI without an HTTP/RPC harness.
//
// settleX402Payment (EIP-3009, USDC):
//   from, to, asset, amount, maxFee, validAfter, validBefore, salt, signature   (9 args)
//   on-chain nonce = keccak256(to, maxFee, salt); contract derives it, so we pass `salt`.
//
// settleX402PaymentDirect (xPNTs):
//   from, to, asset, amount, maxFee, validBefore, nonce, signature              (8 args)
//   note: NO validAfter, and the raw `nonce` (not a salt) is passed directly.

import { type Address, type Hex } from "viem";

export interface EIP3009SettleArgsParams {
  from: Address;
  to: Address;
  asset: Address;
  amount: bigint;
  maxFee: bigint;
  validAfter: bigint;
  validBefore: bigint;
  salt: Hex;
  signature: Hex;
}

export type EIP3009SettleArgs = readonly [
  Address, // from
  Address, // to
  Address, // asset
  bigint, // amount
  bigint, // maxFee
  bigint, // validAfter
  bigint, // validBefore
  Hex, // salt -> on-chain nonce = keccak256(to, maxFee, salt)
  Hex, // signature
];

/** Build the ordered args for X402Facilitator.settleX402Payment (EIP-3009 path). */
export function buildEIP3009SettleArgs(p: EIP3009SettleArgsParams): EIP3009SettleArgs {
  return [
    p.from,
    p.to,
    p.asset,
    p.amount,
    p.maxFee,
    p.validAfter,
    p.validBefore,
    p.salt,
    p.signature,
  ];
}

export interface DirectSettleArgsParams {
  from: Address;
  to: Address;
  asset: Address;
  amount: bigint;
  maxFee: bigint;
  validBefore: bigint;
  nonce: Hex;
  signature: Hex;
}

export type DirectSettleArgs = readonly [
  Address, // from
  Address, // to
  Address, // asset
  bigint, // amount
  bigint, // maxFee
  bigint, // validBefore
  Hex, // nonce
  Hex, // signature
];

/** Build the ordered args for X402Facilitator.settleX402PaymentDirect (direct/xPNTs path). */
export function buildDirectSettleArgs(p: DirectSettleArgsParams): DirectSettleArgs {
  return [p.from, p.to, p.asset, p.amount, p.maxFee, p.validBefore, p.nonce, p.signature];
}
