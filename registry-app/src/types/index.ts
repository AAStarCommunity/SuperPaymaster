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

export type PaymasterVersion = 'v6' | 'v7' | 'v8';

export interface DeployedPaymaster {
  address: string;
  version: PaymasterVersion;
  name: string;
  deployedAt: number;
  owner: string;
  balance: bigint;
  feeRate?: bigint;
  registeredToRouter: boolean;
}

export interface UserOperationExample {
  title: string;
  description: string;
  code: string;
  language: string;
}

export interface NetworkInfo {
  chainId: number;
  name: string;
  icon: string;
  rpcUrl: string;
  explorerUrl: string;
  superPaymasterV6?: string;
  superPaymasterV7?: string;
  superPaymasterV8?: string;
  entryPointV6: string;
  entryPointV7: string;
  entryPointV8: string;
}

export interface PaymasterDeployConfig {
  version: PaymasterVersion;
  name: string;
  initialDeposit: string; // ETH amount
  feeRate: number; // basis points
  autoRegister: boolean;
}

export interface OperatorStats {
  totalEarnings: bigint;
  totalOperations: bigint;
  successRate: number;
  averageFeeRate: number;
  lastOperationTime: number;
}

export interface TransactionStatus {
  hash?: string;
  status: 'pending' | 'confirmed' | 'failed';
  message: string;
}