// Contract addresses and ABIs
export const CONTRACTS = {
  // These will be updated after deployment
  SUPER_PAYMASTER_V6: '0x...',
  SUPER_PAYMASTER_V7: '0x...',
  SUPER_PAYMASTER_V8: '0x...',
  ENTRY_POINT_V6: '0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789',
  ENTRY_POINT_V7: '0x0000000071727De22E5E9d8BAf0edAc6f37da032',
  ENTRY_POINT_V8: '0x0000000071727De22E5E9d8BAf0edAc6f37da032', // Same as v7 for now
};

// Minimal ABIs for the contracts we need to interact with
export const SUPER_PAYMASTER_ABI = [
  {
    "inputs": [
      {"name": "_paymaster", "type": "address"},
      {"name": "_feeRate", "type": "uint256"},
      {"name": "_name", "type": "string"}
    ],
    "name": "registerPaymaster",
    "outputs": [],
    "stateMutability": "nonpayable",
    "type": "function"
  },
  {
    "inputs": [],
    "name": "getBestPaymaster",
    "outputs": [
      {"name": "paymaster", "type": "address"},
      {"name": "feeRate", "type": "uint256"}
    ],
    "stateMutability": "view",
    "type": "function"
  },
  {
    "inputs": [],
    "name": "getActivePaymasters",
    "outputs": [
      {"name": "paymasters", "type": "address[]"}
    ],
    "stateMutability": "view",
    "type": "function"
  },
  {
    "inputs": [
      {"name": "_paymaster", "type": "address"}
    ],
    "name": "getPaymasterInfo",
    "outputs": [
      {
        "components": [
          {"name": "paymaster", "type": "address"},
          {"name": "feeRate", "type": "uint256"},
          {"name": "isActive", "type": "bool"},
          {"name": "successCount", "type": "uint256"},
          {"name": "totalAttempts", "type": "uint256"},
          {"name": "name", "type": "string"}
        ],
        "name": "pool",
        "type": "tuple"
      }
    ],
    "stateMutability": "view",
    "type": "function"
  },
  {
    "inputs": [],
    "name": "getPaymasterCount",
    "outputs": [
      {"name": "count", "type": "uint256"}
    ],
    "stateMutability": "view",
    "type": "function"
  },
  {
    "inputs": [
      {"name": "_newFeeRate", "type": "uint256"}
    ],
    "name": "updateFeeRate",
    "outputs": [],
    "stateMutability": "nonpayable",
    "type": "function"
  },
  {
    "inputs": [],
    "name": "getDeposit",
    "outputs": [
      {"name": "balance", "type": "uint256"}
    ],
    "stateMutability": "view",
    "type": "function"
  },
  {
    "inputs": [],
    "name": "deposit",
    "outputs": [],
    "stateMutability": "payable",
    "type": "function"
  },
  {
    "inputs": [
      {"name": "withdrawAddress", "type": "address"},
      {"name": "amount", "type": "uint256"}
    ],
    "name": "withdrawTo",
    "outputs": [],
    "stateMutability": "nonpayable",
    "type": "function"
  },
  {
    "inputs": [],
    "name": "getVersion",
    "outputs": [
      {"name": "version", "type": "string"}
    ],
    "stateMutability": "pure",
    "type": "function"
  },
  {
    "inputs": [],
    "name": "getRouterStats",
    "outputs": [
      {"name": "totalPaymasters", "type": "uint256"},
      {"name": "activePaymasters", "type": "uint256"},
      {"name": "totalSuccessfulRoutes", "type": "uint256"},
      {"name": "totalRoutes", "type": "uint256"}
    ],
    "stateMutability": "view",
    "type": "function"
  },
  {
    "anonymous": false,
    "inputs": [
      {"indexed": true, "name": "paymaster", "type": "address"},
      {"indexed": false, "name": "feeRate", "type": "uint256"},
      {"indexed": false, "name": "name", "type": "string"}
    ],
    "name": "PaymasterRegistered",
    "type": "event"
  },
  {
    "anonymous": false,
    "inputs": [
      {"indexed": true, "name": "paymaster", "type": "address"},
      {"indexed": true, "name": "user", "type": "address"},
      {"indexed": false, "name": "feeRate", "type": "uint256"}
    ],
    "name": "PaymasterSelected",
    "type": "event"
  }
] as const;

export const ENTRY_POINT_ABI = [
  {
    "inputs": [
      {"name": "account", "type": "address"}
    ],
    "name": "balanceOf",
    "outputs": [
      {"name": "", "type": "uint256"}
    ],
    "stateMutability": "view",
    "type": "function"
  },
  {
    "inputs": [
      {"name": "account", "type": "address"}
    ],
    "name": "depositTo",
    "outputs": [],
    "stateMutability": "payable",
    "type": "function"
  }
] as const;

// Simple Paymaster contract template
export const SIMPLE_PAYMASTER_BYTECODE = {
  v6: "0x...", // Will be populated with actual bytecode
  v7: "0x...", 
  v8: "0x..."
};

export const SIMPLE_PAYMASTER_ABI = [
  {
    "inputs": [
      {"name": "_entryPoint", "type": "address"},
      {"name": "_owner", "type": "address"}
    ],
    "stateMutability": "nonpayable",
    "type": "constructor"
  },
  {
    "inputs": [],
    "name": "deposit",
    "outputs": [],
    "stateMutability": "payable",
    "type": "function"
  },
  {
    "inputs": [],
    "name": "getDeposit",
    "outputs": [
      {"name": "", "type": "uint256"}
    ],
    "stateMutability": "view",
    "type": "function"
  },
  {
    "inputs": [
      {"name": "withdrawAddress", "type": "address"},
      {"name": "amount", "type": "uint256"}
    ],
    "name": "withdrawTo",
    "outputs": [],
    "stateMutability": "nonpayable",
    "type": "function"
  }
] as const;

export type PaymasterVersion = 'v6' | 'v7' | 'v8';

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