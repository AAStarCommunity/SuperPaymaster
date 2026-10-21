#!/usr/bin/env node
// M-11: read version() + ERC-1967 impl slot + runtime codehash of the contracts downstream
// consumes today on a target network, pinned to one block. Read-only.
// Usage: RPC_URL=<url> node scripts/m11-onchain-versions.mjs [deployments/config.sepolia.json] > out.json
// The RPC URL is taken from the environment and never written to the output.
import { readFileSync } from 'node:fs';
import { createPublicClient, http, keccak256, parseAbi } from 'viem';

const cfgPath = process.argv[2] || 'deployments/config.sepolia.json';
const url = process.env.RPC_URL;
if (!url) { console.error('RPC_URL not set'); process.exit(2); }
const cfg = JSON.parse(readFileSync(cfgPath, 'utf8'));
const c = createPublicClient({ transport: http(url, { retryCount: 3, timeout: 30000 }) });
const IMPL_SLOT = '0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc';
const abi = parseAbi(['function version() view returns (string)']);

const block = await c.getBlockNumber();
const chainId = await c.getChainId();
const out = { network: cfgPath, chainId, block: String(block), contracts: {} };
for (const [k, v] of Object.entries(cfg)) {
  if (typeof v !== 'string' || !/^0x[0-9a-fA-F]{40}$/.test(v)) continue;
  const row = { address: v };
  const code = await c.getCode({ address: v, blockNumber: block });
  row.codeSize = code ? (code.length - 2) / 2 : 0;
  row.runtimeCodehash = code && code !== '0x' ? keccak256(code) : null;
  try { row.version = await c.readContract({ address: v, abi, functionName: 'version', blockNumber: block }); }
  catch { row.version = null; }
  const slot = await c.getStorageAt({ address: v, slot: IMPL_SLOT, blockNumber: block });
  if (slot && BigInt(slot) !== 0n) {
    const impl = '0x' + slot.slice(26);
    row.erc1967Impl = impl;
    const ic = await c.getCode({ address: impl, blockNumber: block });
    row.implCodehash = ic && ic !== '0x' ? keccak256(ic) : null;
    row.implCodeSize = ic ? (ic.length - 2) / 2 : 0;
  }
  out.contracts[k] = row;
}
console.log(JSON.stringify(out, null, 1));
