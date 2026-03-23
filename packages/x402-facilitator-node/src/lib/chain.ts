// viem client setup for on-chain interactions

import {
  createPublicClient,
  createWalletClient,
  http,
  type PublicClient,
  type WalletClient,
  type Chain,
} from "viem";
import { privateKeyToAccount, type PrivateKeyAccount } from "viem/accounts";
import { sepolia, base, baseSepolia } from "viem/chains";
import { type Config } from "./config.js";

const CHAINS: Record<number, Chain> = {
  11155111: sepolia,
  8453: base,
  84532: baseSepolia,
};

let _publicClient: PublicClient | null = null;
let _walletClient: WalletClient | null = null;
let _account: PrivateKeyAccount | null = null;

export function initClients(config: Config) {
  const chain = CHAINS[config.chainId];
  if (!chain) throw new Error(`Unsupported chainId: ${config.chainId}`);

  _account = privateKeyToAccount(config.operatorPrivateKey);

  _publicClient = createPublicClient({
    chain,
    transport: http(config.rpcUrl),
  });

  _walletClient = createWalletClient({
    account: _account,
    chain,
    transport: http(config.rpcUrl),
  });
}

export function getPublicClient(): PublicClient {
  if (!_publicClient) throw new Error("Clients not initialized. Call initClients first.");
  return _publicClient;
}

export function getWalletClient(): WalletClient {
  if (!_walletClient) throw new Error("Clients not initialized. Call initClients first.");
  return _walletClient;
}

export function getAccount(): PrivateKeyAccount {
  if (!_account) throw new Error("Account not initialized. Call initClients first.");
  return _account;
}
