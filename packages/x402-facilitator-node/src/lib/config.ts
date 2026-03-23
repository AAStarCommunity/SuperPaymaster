// Environment configuration for Facilitator Node

export interface Config {
  port: number;
  chainId: number;
  rpcUrl: string;
  operatorPrivateKey: `0x${string}`;
  superPaymasterAddress: `0x${string}`;
  usdcAddress: `0x${string}`;
  network: string;
  baseUrl: string;
}

function requireEnv(key: string): string {
  const val = process.env[key];
  if (!val) throw new Error(`Missing required env: ${key}`);
  return val;
}

export function loadConfig(): Config {
  const chainId = Number(process.env.CHAIN_ID || "11155111");

  // Default USDC addresses by chain
  const usdcDefaults: Record<number, string> = {
    11155111: "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238", // Sepolia
    8453: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913", // Base
    84532: "0x036CbD53842c5426634e7929541eC2318f3dCF7e", // Base Sepolia
  };

  return {
    port: Number(process.env.PORT || "3402"),
    chainId,
    rpcUrl: requireEnv("RPC_URL"),
    operatorPrivateKey: requireEnv("OPERATOR_PRIVATE_KEY") as `0x${string}`,
    superPaymasterAddress: requireEnv("SUPER_PAYMASTER_ADDRESS") as `0x${string}`,
    usdcAddress: (() => {
      const addr = process.env.USDC_ADDRESS || usdcDefaults[chainId];
      if (!addr) throw new Error(`No USDC address for chainId ${chainId}. Set USDC_ADDRESS env var.`);
      return addr as `0x${string}`;
    })(),
    network: process.env.NETWORK || "sepolia",
    baseUrl: process.env.BASE_URL || `http://localhost:${process.env.PORT || "3402"}`,
  };
}
