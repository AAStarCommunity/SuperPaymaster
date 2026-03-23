// x402 Protocol types for Facilitator Node

export interface VerifyRequest {
  /** x402 payment payload (base64 or JSON) */
  payload: string;
  /** Payment details */
  payment: {
    from: `0x${string}`;
    to: `0x${string}`;
    asset: `0x${string}`;
    amount: string;
    nonce: `0x${string}`;
    validAfter: string;
    validBefore: string;
    signature: `0x${string}`;
  };
  /** Settlement scheme */
  scheme: "eip-3009" | "permit2" | "direct";
}

export interface VerifyResponse {
  valid: boolean;
  reason?: string;
  payer?: `0x${string}`;
  amount?: string;
  asset?: `0x${string}`;
}

export interface SettleRequest {
  /** Same payload from verify step */
  payload: string;
  payment: {
    from: `0x${string}`;
    to: `0x${string}`;
    asset: `0x${string}`;
    amount: string;
    nonce: `0x${string}`;
    validAfter: string;
    validBefore: string;
    signature: `0x${string}`;
  };
  scheme: "eip-3009" | "permit2" | "direct";
}

export interface SettleResponse {
  success: boolean;
  txHash?: `0x${string}`;
  settlementId?: `0x${string}`;
  error?: string;
}

export interface QuoteResponse {
  feeBPS: number;
  feePercent: string;
  supportedAssets: Array<{
    address: `0x${string}`;
    symbol: string;
    network: string;
  }>;
  supportedSchemes: string[];
}

export interface PaymentInfo {
  facilitator: `0x${string}`;
  network: string;
  chainId: number;
  supportedAssets: Array<{
    address: `0x${string}`;
    symbol: string;
  }>;
  feeBPS: number;
  verifyUrl: string;
  settleUrl: string;
  quoteUrl: string;
}

export interface HealthResponse {
  status: "ok" | "degraded" | "down";
  version: string;
  chainId: number;
  network: string;
  operator: `0x${string}`;
  contractVersion?: string;
  blockNumber?: number;
}
