#!/usr/bin/env node
// READ-ONLY probes of the target chains (no transaction is signed or sent):
//   1. eth_config (EIP-7910) on Sepolia                      -> current / next fork
//   2. CLZ probe (EIP-7939, Osaka): eth_call with a state override that runs
//      PUSH1 1; CLZ; PUSH1 0; MSTORE; PUSH1 32; PUSH1 0; RETURN  -> 0x..ff (clz(1) = 255) iff Osaka
//      on Sepolia, OP mainnet, OP Sepolia, plus NEGATIVE / POSITIVE controls on local anvil
//      (--hardfork prague must fail with NotActivated, --hardfork osaka must return 0xff)
//   3. EntryPoint v0.7 runtime codehash on the three chains (expected 0x8db5ff69…fc58)
//   4. EntryPoint.getDepositInfo(SP) on Sepolia (SP 5.4.2 proxy) and OP mainnet (V3 SP)
// Every raw JSON-RPC request/response is written to the output file.
//
// Usage: node script/evidence/fork-level-probes.mjs <out.json> [anvilPragueRpc anvilOsakaRpc]
import { writeFileSync } from 'node:fs';

const [out, anvilPrague, anvilOsaka] = process.argv.slice(2);
if (!out) { console.error('usage: fork-level-probes.mjs <out.json> [anvilPragueRpc anvilOsakaRpc]'); process.exit(2); }

const CHAINS = {
  sepolia: 'https://ethereum-sepolia-rpc.publicnode.com',
  'op-mainnet': 'https://mainnet.optimism.io',
  'op-sepolia': 'https://sepolia.optimism.io',
};
const EP = '0x0000000071727De22E5E9d8BAf0edAc6f37da032';
const EP_CODEHASH = '0x8db5ff695839d655407cc8490bb7a5d82337a86a6b39c3f0258aa6c3b582fc58';
const SPS = { sepolia: '0x09DF0d2e3722EC0e401fE3819E64278a42ae4DE9', 'op-mainnet': '0xA2c9A6e95f19f5D2a364CBCbB5f0b32B1B4d140E' };
const PROBE = '0x0000000000000000000000000000000000c1c1c1';
const CLZ_CODE = '0x60011e60005260206000f3';

const log = [];
let id = 0;
async function rpc(label, url, method, params) {
  const req = { jsonrpc: '2.0', id: ++id, method, params };
  let res;
  try {
    const r = await fetch(url, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(req) });
    res = await r.json();
  } catch (e) {
    res = { transportError: String(e) };
  }
  log.push({ label, endpoint: url.startsWith('http://127.0.0.1') ? url.replace(/:\d+$/, ':<local port>') : url, request: req, response: res });
  return res;
}

// keccak256 via viem (repo dependency)
const { keccak256 } = await import('viem');

const summary = { utc: new Date().toISOString(), chains: {} };
for (const [name, url] of Object.entries(CHAINS)) {
  const s = {};
  s.chainId = parseInt((await rpc(`${name} chainId`, url, 'eth_chainId', [])).result, 16);
  s.blockNumber = parseInt((await rpc(`${name} blockNumber`, url, 'eth_blockNumber', [])).result, 16);
  if (name === 'sepolia') {
    const c = await rpc(`${name} eth_config`, url, 'eth_config', []);
    s.eth_config = c.result ? { currentActivationTime: c.result.current?.activationTime, currentForkId: c.result.current?.forkId,
      blobSchedule: c.result.current?.blobSchedule, next: c.result.next ?? null } : { error: c.error || c.transportError };
  }
  const clz = await rpc(`${name} CLZ probe`, url, 'eth_call', [{ to: PROBE, data: '0x' }, 'latest', { [PROBE]: { code: CLZ_CODE } }]);
  s.clz = clz.result ?? { error: clz.error || clz.transportError };
  s.osakaByClz = clz.result ? BigInt(clz.result) === 255n : false;
  const code = await rpc(`${name} EP code`, url, 'eth_getCode', [EP, 'latest']);
  s.entryPointCodehash = code.result ? keccak256(code.result) : null;
  s.entryPointCodehashMatches = s.entryPointCodehash === EP_CODEHASH;
  if (SPS[name]) {
    // getDepositInfo(address) = 0x5287ce12
    const di = await rpc(`${name} EP.getDepositInfo(SP)`, url, 'eth_call',
      [{ to: EP, data: '0x5287ce12' + SPS[name].slice(2).toLowerCase().padStart(64, '0') }, 'latest']);
    if (di.result) {
      const h = di.result.slice(2); const w = (i) => BigInt('0x' + h.slice(i * 64, i * 64 + 64));
      s.spDepositInfo = { sp: SPS[name], deposit: w(0).toString(), staked: w(1) === 1n, stake: w(2).toString(), unstakeDelaySec: Number(w(3)), withdrawTime: Number(w(4)) };
    }
  }
  summary.chains[name] = s;
}
for (const [name, url] of [['anvil --hardfork prague (negative control)', anvilPrague], ['anvil --hardfork osaka (positive control)', anvilOsaka]]) {
  if (!url) continue;
  const clz = await rpc(`${name} CLZ probe`, url, 'eth_call', [{ to: PROBE, data: '0x' }, 'latest', { [PROBE]: { code: CLZ_CODE } }]);
  summary.chains[name] = { clz: clz.result ?? { error: clz.error || clz.transportError }, osakaByClz: clz.result ? BigInt(clz.result) === 255n : false };
}
writeFileSync(out, JSON.stringify({ category: 'onchain-readonly', note: 'read-only JSON-RPC; nothing signed or sent', summary, raw: log }, null, 2) + '\n');
console.log(JSON.stringify(summary, null, 2));
