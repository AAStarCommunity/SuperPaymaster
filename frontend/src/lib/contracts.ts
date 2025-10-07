// Import Registry v1.2 ABI
import SuperPaymasterRegistryV1_2_ABI from "./SuperPaymasterRegistry_v1_2.json";

// Contract addresses and ABIs
export const CONTRACTS = {
  // These will be updated after deployment
  SUPER_PAYMASTER_V6: "0x...",
  SUPER_PAYMASTER_V7: "0x...",
  SUPER_PAYMASTER_V8: "0x...",
  // SuperPaymaster Registry v1.2 (TODO: Update after deployment)
  SUPER_PAYMASTER_REGISTRY_V1_2: "0x...",
  ENTRY_POINT_V6: "0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789",
  ENTRY_POINT_V7: "0x0000000071727De22E5E9d8BAf0edAc6f37da032",
  ENTRY_POINT_V8: "0x0000000071727De22E5E9d8BAf0edAc6f37da032", // Same as v7 for now
};

// Minimal ABIs for the contracts we need to interact with
export const SUPER_PAYMASTER_ABI = [
  {
    inputs: [
      { name: "_paymaster", type: "address" },
      { name: "_feeRate", type: "uint256" },
      { name: "_name", type: "string" },
    ],
    name: "registerPaymaster",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
  {
    inputs: [],
    name: "getBestPaymaster",
    outputs: [
      { name: "paymaster", type: "address" },
      { name: "feeRate", type: "uint256" },
    ],
    stateMutability: "view",
    type: "function",
  },
  {
    inputs: [],
    name: "getActivePaymasters",
    outputs: [{ name: "paymasters", type: "address[]" }],
    stateMutability: "view",
    type: "function",
  },
  {
    inputs: [{ name: "_paymaster", type: "address" }],
    name: "getPaymasterInfo",
    outputs: [
      {
        components: [
          { name: "paymaster", type: "address" },
          { name: "feeRate", type: "uint256" },
          { name: "isActive", type: "bool" },
          { name: "successCount", type: "uint256" },
          { name: "totalAttempts", type: "uint256" },
          { name: "name", type: "string" },
        ],
        name: "pool",
        type: "tuple",
      },
    ],
    stateMutability: "view",
    type: "function",
  },
  {
    inputs: [],
    name: "getPaymasterCount",
    outputs: [{ name: "count", type: "uint256" }],
    stateMutability: "view",
    type: "function",
  },
  {
    inputs: [{ name: "_newFeeRate", type: "uint256" }],
    name: "updateFeeRate",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
  {
    inputs: [],
    name: "getDeposit",
    outputs: [{ name: "balance", type: "uint256" }],
    stateMutability: "view",
    type: "function",
  },
  {
    inputs: [],
    name: "deposit",
    outputs: [],
    stateMutability: "payable",
    type: "function",
  },
  {
    inputs: [
      { name: "withdrawAddress", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    name: "withdrawTo",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
  {
    inputs: [],
    name: "getVersion",
    outputs: [{ name: "version", type: "string" }],
    stateMutability: "pure",
    type: "function",
  },
  {
    inputs: [],
    name: "getRouterStats",
    outputs: [
      { name: "totalPaymasters", type: "uint256" },
      { name: "activePaymasters", type: "uint256" },
      { name: "totalSuccessfulRoutes", type: "uint256" },
      { name: "totalRoutes", type: "uint256" },
    ],
    stateMutability: "view",
    type: "function",
  },
  {
    anonymous: false,
    inputs: [
      { indexed: true, name: "paymaster", type: "address" },
      { indexed: false, name: "feeRate", type: "uint256" },
      { indexed: false, name: "name", type: "string" },
    ],
    name: "PaymasterRegistered",
    type: "event",
  },
  {
    anonymous: false,
    inputs: [
      { indexed: true, name: "paymaster", type: "address" },
      { indexed: true, name: "user", type: "address" },
      { indexed: false, name: "feeRate", type: "uint256" },
    ],
    name: "PaymasterSelected",
    type: "event",
  },
] as const;

export const ENTRY_POINT_ABI = [
  {
    inputs: [{ name: "account", type: "address" }],
    name: "balanceOf",
    outputs: [{ name: "", type: "uint256" }],
    stateMutability: "view",
    type: "function",
  },
  {
    inputs: [{ name: "account", type: "address" }],
    name: "depositTo",
    outputs: [],
    stateMutability: "payable",
    type: "function",
  },
] as const;

// Pimlico Singleton Paymaster contract templates
export const SINGLETON_PAYMASTER_BYTECODE = {
  v6: "0x...", // Will be populated with actual bytecode from SingletonPaymasterV6.sol
  v7: "0x...", // Will be populated with actual bytecode from SingletonPaymasterV7.sol
  v8: "0x...", // Will be populated with actual bytecode from SingletonPaymasterV8.sol
};

export const SINGLETON_PAYMASTER_ABI = [
  // Constructor (varies by version, but all have these 4 parameters)
  {
    inputs: [
      { name: "_entryPoint", type: "address" },
      { name: "_owner", type: "address" },
      { name: "_manager", type: "address" },
      { name: "_signers", type: "address[]" },
    ],
    stateMutability: "nonpayable",
    type: "constructor",
  },
  // BasePaymaster functions
  {
    inputs: [],
    name: "deposit",
    outputs: [],
    stateMutability: "payable",
    type: "function",
  },
  {
    inputs: [],
    name: "getDeposit",
    outputs: [{ name: "", type: "uint256" }],
    stateMutability: "view",
    type: "function",
  },
  {
    inputs: [
      { name: "withdrawAddress", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    name: "withdrawTo",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
  {
    inputs: [{ name: "unstakeDelaySec", type: "uint32" }],
    name: "addStake",
    outputs: [],
    stateMutability: "payable",
    type: "function",
  },
  {
    inputs: [],
    name: "unlockStake",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
  {
    inputs: [{ name: "withdrawAddress", type: "address" }],
    name: "withdrawStake",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
  // MultiSigner functions
  {
    inputs: [
      { name: "signers", type: "address[]" },
      { name: "allowed", type: "bool" },
    ],
    name: "updateSignersList",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
  {
    inputs: [
      { name: "bundlers", type: "address[]" },
      { name: "allowed", type: "bool" },
    ],
    name: "updateBundlerAllowlist",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
  // EntryPoint interface functions (V6 vs V7/V8 have different signatures)
  {
    inputs: [
      {
        name: "userOp",
        type: "tuple",
        components: [
          { name: "sender", type: "address" },
          { name: "nonce", type: "uint256" },
          { name: "callGasLimit", type: "uint256" },
          { name: "verificationGasLimit", type: "uint256" },
          { name: "preVerificationGas", type: "uint256" },
          { name: "maxFeePerGas", type: "uint256" },
          { name: "maxPriorityFeePerGas", type: "uint256" },
          { name: "callData", type: "bytes" },
          { name: "initCode", type: "bytes" },
          { name: "paymasterAndData", type: "bytes" },
        ],
      },
      { name: "userOpHash", type: "bytes32" },
      { name: "requiredPreFund", type: "uint256" },
    ],
    name: "validatePaymasterUserOp",
    outputs: [
      { name: "context", type: "bytes" },
      { name: "validationData", type: "uint256" },
    ],
    stateMutability: "nonpayable",
    type: "function",
  },
  // Helper functions
  {
    inputs: [
      { name: "_mode", type: "uint8" },
      {
        name: "_userOp",
        type: "tuple",
        components: [
          { name: "sender", type: "address" },
          { name: "nonce", type: "uint256" },
          { name: "callGasLimit", type: "uint256" },
          { name: "verificationGasLimit", type: "uint256" },
          { name: "preVerificationGas", type: "uint256" },
          { name: "maxFeePerGas", type: "uint256" },
          { name: "maxPriorityFeePerGas", type: "uint256" },
          { name: "callData", type: "bytes" },
          { name: "initCode", type: "bytes" },
          { name: "paymasterAndData", type: "bytes" },
        ],
      },
    ],
    name: "getHash",
    outputs: [{ name: "", type: "bytes32" }],
    stateMutability: "view",
    type: "function",
  },
  // Events
  {
    anonymous: false,
    inputs: [
      { indexed: true, name: "userOpHash", type: "bytes32" },
      { indexed: true, name: "sender", type: "address" },
      { indexed: false, name: "mode", type: "uint8" },
      { indexed: false, name: "token", type: "address" },
      { indexed: false, name: "costInToken", type: "uint256" },
      { indexed: false, name: "exchangeRate", type: "uint256" },
    ],
    name: "UserOperationSponsored",
    type: "event",
  },
] as const;

export type PaymasterVersion = "v6" | "v7" | "v8";

export interface PaymasterInfo {
  paymaster: string;
  feeRate: bigint;
  isActive: boolean;
  successCount: bigint;
  totalAttempts: bigint;
  name: string;
}

export interface RouterStats {
  totalPaymasters: bigint;
  activePaymasters: bigint;
  totalSuccessfulRoutes: bigint;
  totalRoutes: bigint;
}

// Export SuperPaymaster Registry v1.2 ABI
export const SUPER_PAYMASTER_REGISTRY_V1_2_ABI =
  SuperPaymasterRegistryV1_2_ABI as const;
