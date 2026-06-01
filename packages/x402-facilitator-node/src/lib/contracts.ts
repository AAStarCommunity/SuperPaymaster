// Contract ABIs and interaction helpers
//
// @deprecated This in-repo facilitator node is superseded by the @aastar/x402 SDK.
// The x402 settlement ABI below tracks SuperPaymaster's C-02/C-03 signature-required
// settlement (commit d7df0c3e): settleX402PaymentDirect now needs the payer's EIP-712
// X402PaymentAuthorization signature; settleX402Payment binds the recipient via
// nonce = keccak256(to, salt). Full signing-flow integration lives in the SDK —
// see https://github.com/AAStarCommunity/aastar-sdk/issues/39.

import { type Abi } from "viem";

// Minimal ABI for SuperPaymaster x402 functions
export const SUPER_PAYMASTER_ABI = [
  {
    name: "settleX402Payment",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      { name: "from", type: "address" },
      { name: "to", type: "address" },
      { name: "asset", type: "address" },
      { name: "amount", type: "uint256" },
      { name: "validAfter", type: "uint256" },
      { name: "validBefore", type: "uint256" },
      // C-03: recipient bound via on-chain nonce = keccak256(to, salt). Pass `salt`.
      { name: "salt", type: "bytes32" },
      { name: "signature", type: "bytes" },
    ],
    outputs: [{ name: "settlementId", type: "bytes32" }],
  },
  {
    name: "settleX402PaymentDirect",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      { name: "from", type: "address" },
      { name: "to", type: "address" },
      { name: "asset", type: "address" },
      { name: "amount", type: "uint256" },
      // C-02: payer EIP-712 X402PaymentAuthorization required (see aastar-sdk#39).
      { name: "maxFee", type: "uint256" },
      { name: "validBefore", type: "uint256" },
      { name: "nonce", type: "bytes32" },
      { name: "signature", type: "bytes" },
    ],
    outputs: [{ name: "settlementId", type: "bytes32" }],
  },
  {
    name: "facilitatorFeeBPS",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    name: "facilitatorEarnings",
    type: "function",
    stateMutability: "view",
    inputs: [
      { name: "operator", type: "address" },
      { name: "token", type: "address" },
    ],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    name: "x402SettlementNonces",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "nonce", type: "bytes32" }],
    outputs: [{ name: "", type: "bool" }],
  },
  {
    name: "version",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "string" }],
  },
  {
    name: "isEligibleForSponsorship",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "user", type: "address" }],
    outputs: [{ name: "", type: "bool" }],
  },
] as const satisfies Abi;

// ERC-20 minimal ABI for balance checks
export const ERC20_ABI = [
  {
    name: "balanceOf",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    name: "symbol",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "string" }],
  },
  {
    name: "decimals",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint8" }],
  },
] as const satisfies Abi;
